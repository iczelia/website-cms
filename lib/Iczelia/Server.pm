# iczelia.net - personal CMS and static site engine.
# Copyright (C) 2026 Kamila Szewczyk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

package Iczelia::Server;
use strict;
use warnings;
use IO::Socket::INET ();
use IO::Socket::UNIX ();
use POSIX            qw(:sys_wait_h);
use Errno            qw(EINTR);
use Socket           qw(IPPROTO_TCP TCP_NODELAY SOL_SOCKET);
use Time::HiRes      qw();
use Carp             qw(croak);

use Iczelia::HTTP;
use Iczelia::Router;
use Iczelia::Minify   ();
use Iczelia::Compress ();

# Requests slower than this print a SLOW marker plus a timing
# breakdown. Override via $ENV{ICZELIA_SLOW_REQ_S}.
our $SLOW_REQ_S =
  defined $ENV{ICZELIA_SLOW_REQ_S}
  ? $ENV{ICZELIA_SLOW_REQ_S} + 0
  : 0.25;

# Forwarding headers from any other peer are ignored. 'unix' covers
# UNIX-socket peers; the deploy is expected to expose the socket via
# group iczelia (mode 0660). ::ffff:127.0.0.1 covers IPv4-mapped
# loopback under dual-stack listeners.
my %TRUSTED_HOPS = map {$_ => 1} qw(127.0.0.1 ::1 ::ffff:127.0.0.1 unix);

sub new {
  my ($class, %arg) = @_;
  croak "config required" unless $arg{config};
  my $self = bless {
    cfg        => $arg{config},
    listener   => undef,
    router     => undef,
    cache      => $arg{cache},
    workers    => {},                 # pid => 1
    running    => 1,
    on_request => $arg{on_request},
  }, $class;
  return $self;
}

sub cache {
  my ($self, $c) = @_;
  $self->{cache} = $c if $c;
  $self->{cache};
}

# Optional setters/getters wired by App::build:
#   router            request dispatcher
#   dynamic_lookup    router-miss fallback for admin-defined dynamic pages
#   analytics_db      enables per-request analytics logging
#   not_found_handler turns 404 plain-text responses into themed HTML
#   warmer_callback   runs once in a niced child fork; respawns on return
for my $attr (
  qw(router dynamic_lookup analytics_db
  not_found_handler warmer_callback)
  )
{
  no strict 'refs';
  *{__PACKAGE__ . "::$attr"} = sub {
    my ($self, $v) = @_;
    $self->{$attr} = $v if defined $v;
    $self->{$attr};
  };
}

sub run {
  my ($self) = @_;
  $self->_open_listener;
  $self->_install_signals;
  $SIG{PIPE} = 'IGNORE';

  my $want = $self->{cfg}{workers} || 4;

  while ($self->{running}) {
    while ($self->{running} && scalar(keys %{$self->{workers}}) < $want) {
      $self->_spawn_worker;
    }
    if ($self->{warmer_callback}
      && !($self->{warmer_pid} && kill 0, $self->{warmer_pid}))
    {
      $self->_spawn_warmer;
    }
    my $kid = waitpid(-1, 0);
    if ($kid > 0) {
      if ($self->{warmer_pid} && $kid == $self->{warmer_pid}) {
        delete $self->{warmer_pid};
      }
      else {
        delete $self->{workers}{$kid};
      }
    }
    elsif ($! != EINTR) {
      last;
    }
  }

  # Shutting down: ask workers + warmer to exit.
  kill 'TERM', $_ for keys %{$self->{workers}};
  kill 'TERM', $self->{warmer_pid} if $self->{warmer_pid};
  while (%{$self->{workers}} || $self->{warmer_pid}) {
    my $kid = waitpid(-1, 0);
    last if $kid == -1 && $! != EINTR;
    if ($kid > 0) {
      if ($self->{warmer_pid} && $kid == $self->{warmer_pid}) {
        delete $self->{warmer_pid};
      }
      else {
        delete $self->{workers}{$kid};
      }
    }
  }
  if ($self->{listener}) {
    close $self->{listener};
    if ($self->{cfg}{'listen-socket'} && -S $self->{cfg}{'listen-socket'}) {
      unlink $self->{cfg}{'listen-socket'};
    }
  }
}

sub _spawn_warmer {
  my ($self) = @_;
  my $pid = fork();
  croak "fork (warmer): $!" unless defined $pid;
  if ($pid == 0) {
    $SIG{TERM} = sub {exit 0};
    $SIG{INT}  = sub {exit 0};
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';

    # Yield CPU to the request workers; warming is best-effort.
    eval {POSIX::nice(10)};
    eval {$self->{warmer_callback}->()};
    warn "warmer error: $@" if $@;
    exit 0;
  }
  $self->{warmer_pid} = $pid;
}

sub _open_listener {
  my ($self) = @_;
  my $cfg = $self->{cfg};
  if ($cfg->{'listen-socket'}) {
    my $path = $cfg->{'listen-socket'};
    unlink $path if -e $path;
    $self->{listener} = IO::Socket::UNIX->new(
      Local  => $path,
      Listen => 128,
      Type   => IO::Socket::UNIX::SOCK_STREAM(),
    ) or croak "listen unix $path: $!";
    chmod 0660, $path;
  }
  else {
    my ($host, $port) = split /:/, $cfg->{'listen-tcp'}, 2;
    $self->{listener} = IO::Socket::INET->new(
      LocalAddr => $host,
      LocalPort => $port,
      Listen    => 128,
      ReuseAddr => 1,
      Proto     => 'tcp',
    ) or croak "listen tcp $cfg->{'listen-tcp'}: $!";
  }
  $self->{listener}->blocking(1);
}

sub _install_signals {
  my ($self) = @_;
  my $stop = sub {$self->{running} = 0};
  $SIG{TERM} = $stop;
  $SIG{INT}  = $stop;
  $SIG{HUP}  = $stop;
  $SIG{CHLD} = sub {
    while ((my $kid = waitpid(-1, WNOHANG)) > 0) {
      delete $self->{workers}{$kid};
    }
  };
}

sub _spawn_worker {
  my ($self) = @_;
  my $pid = fork();
  croak "fork: $!" unless defined $pid;
  if ($pid == 0) {
    $SIG{TERM} = sub {exit 0};
    $SIG{INT}  = sub {exit 0};
    $SIG{HUP}  = 'DEFAULT';
    $SIG{CHLD} = 'DEFAULT';
    $self->_worker_loop;
    exit 0;
  }
  $self->{workers}{$pid} = 1;
}

sub _worker_loop {
  my ($self)     = @_;
  my $cfg        = $self->{cfg};
  my $max        = $cfg->{'max-requests'}      || 500;
  my $ka_timeout = $cfg->{'keepalive-timeout'} || 0.25;
  my $ka_max     = $cfg->{'keepalive-max'}     || 30;
  my $first_to   = $cfg->{'request-timeout'}   || 15;
  my $listener   = $self->{listener};
  my $lfd        = fileno($listener);
  my $served     = 0;

  while ($served < $max) {
    my $cli = $listener->accept;
    unless ($cli) {
      next if $! == EINTR;
      last;
    }
    $cli->blocking(1);

    # TCP_NODELAY: avoid 40ms delayed-ACK on small keep-alive responses.
    if ($cli->isa('IO::Socket::INET')) {
      setsockopt($cli, IPPROTO_TCP, TCP_NODELAY, 1);
    }
    my $cfd = fileno($cli);

    my $on_conn  = 0;
    my $io_state = Iczelia::HTTP::make_state();
    while (1) {
      ++$on_conn;
      my $is_last = ($on_conn >= $ka_max) || ($served + 1 >= $max);
      my $first   = ($on_conn == 1);

      # When idling on keep-alive, also watch the listener:
      # close this idle conn the moment new work arrives so the
      # backlog doesn't pile up behind a parked worker.
      if (!$first && !length $io_state->{buf}) {
        my $rin = '';
        vec($rin, $cfd, 1) = 1;
        vec($rin, $lfd, 1) = 1;
        my $nfound = select(my $rout = $rin, undef, undef, $ka_timeout);
        last if $nfound <= 0;
        last if vec($rout, $lfd, 1) && !vec($rout, $cfd, 1);
      }

      my $verdict;
      eval {
        $verdict = $self->_handle_one(
          $cli,
          state      => $io_state,
          timeout    => $first ? $first_to : $ka_timeout,
          is_last    => $is_last,
          ka_timeout => $ka_timeout,
          ka_max     => $ka_max,
        );
        1;
      } or do {
        warn "worker error: $@";
        $verdict = 'close';
      };
      ++$served;
      last if !defined $verdict || $verdict eq 'close';
      last if $served >= $max;
    }
    close $cli;
  }
}

sub _handle_one {
  my ($self, $cli, %opt) = @_;
  my $cap     = $self->{cfg}{'request-cap'};
  my $timeout = $opt{timeout};

  my $req = Iczelia::HTTP::read_request(
    $cli,
    cap     => $cap,
    timeout => $timeout,
    state   => $opt{state},
  );
  return 'close' unless $req;
  if (ref $req eq 'HASH' && $req->{_bad}) {
    my $r = Iczelia::HTTP::error($req->{_status} || 400, $req->{_why});
    Iczelia::HTTP::write_response($cli, $r);
    return 'close';
  }
  my $t_handle_start = Time::HiRes::time();

  my $peer = _peer_addr($cli);
  $req->{remote} = $peer;

  # X-Real-IP wins over X-Forwarded-For because the latter is
  # client-appendable. Only honoured from a trusted upstream.
  if ($TRUSTED_HOPS{$peer}) {
    my $real = $req->{headers}{'x-real-ip'};
    if (defined $real) {$real =~ s/^\s+//; $real =~ s/\s+$//}
    if (defined $real && length $real) {
      $req->{remote} = $real;
    }
    else {
      my $xff = $req->{headers}{'x-forwarded-for'};
      if (defined $xff && length $xff) {
        my @hops = grep {length} map {
          my $h = $_;
          $h =~ s/^\s+//;
          $h =~ s/\s+$//;
          $h
        } split /,/, $xff;
        $req->{remote} = $hops[-1] if @hops;
      }
    }
  }

  my $cache_key = _cache_key_for($self, $req);
  if ($cache_key) {
    my $hit = eval {$self->{cache}->get($cache_key, $req)};
    if (!$@ && $hit) {
      my $ka = _decide_keep_alive($req, \%opt);
      if ($ka) {
        $hit->{_keep_alive}         = 1;
        $hit->{_keep_alive_timeout} = $opt{ka_timeout};
        $hit->{_keep_alive_max}     = $opt{ka_max};
      }
      _compress_uncached($req, $hit);   # for rows the warmer hasn't reached
      Iczelia::HTTP::write_response($cli, $hit);
      _log_request(
        $req, $hit,
        {
          total   => Time::HiRes::time() - $t_handle_start,
          handler => 0,
          cache   => Time::HiRes::time() - $t_handle_start,
          hit     => 1,
        }
      );
      return $ka ? 'keep' : 'close';
    }
  }

  my $t_handler_start = Time::HiRes::time();
  my $resp;
  eval {
    if ($self->{on_request}) {
      $resp = $self->{on_request}->($req);
    }
    elsif ($self->{router}) {
      my ($h, $caps, $matched_path) =
        $self->{router}->match($req->{method}, $req->{path});
      if ($h) {
        $req->{caps} = $caps;
        $resp = $h->($req);
      }
      elsif ($matched_path) {
        $resp = Iczelia::HTTP::error(405);
      }
      else {
        # Let admin-defined dynamic pages claim the path before 404.
        $resp =
            $self->{dynamic_lookup}
          ? $self->{dynamic_lookup}->($req)
          : undef;
        $resp ||= Iczelia::HTTP::error(404);
      }
    }
    else {
      $resp = Iczelia::HTTP::error(503, 'no handler configured');
    }
    1;
  } or do {
    my $err = $@ || 'unknown error';
    warn "handler error: $req->{method} $req->{path}: $err";
    $resp = Iczelia::HTTP::error(500);
  };

  $resp ||= Iczelia::HTTP::error(500, 'no response');
  my $t_handler_end = Time::HiRes::time();

  # Themify plain-text 404s; HTML 404s came from a handler that
  # already built its own body.
  if (($resp->{status} // 0) == 404 && $self->{not_found_handler}) {
    my $ct = ($resp->{headers} && $resp->{headers}{'Content-Type'}) // '';
    if ($ct =~ m{^text/plain}i || $ct eq '') {
      my $themed = eval {$self->{not_found_handler}->($req)};
      if (!$@ && $themed) {
        $themed->{status} = 404;
        $resp = $themed;
      }
    }
  }

  # put() returns the canonical (ETag-stamped) response so the first
  # visitor sees what subsequent cache hits will see.
  my $minified = 0;
  if ( $cache_key
    && ($resp->{status} || 200) == 200
    && !$resp->{_no_cache}
    && (!$resp->{cookies} || !@{$resp->{cookies}}))
  {
    eval {
      my $stored = $self->{cache}->put($cache_key, $resp);
      if ($stored) {$resp = $stored; $minified = 1}
      1;
    } or do {
      warn "cache put failed: $@";
    };
  }

  # uncached pages skip put()'s minify pass; do it here
  if ( !$minified
    && ($resp->{status} || 200) == 200
    && $resp->{headers}
    && ($resp->{headers}{'Content-Type'} // '') =~ m{^text/html\b}i
    && defined $resp->{body}
    && length $resp->{body})
  {
    $resp->{body} = Iczelia::Minify::html($resp->{body});
  }

  _compress_uncached($req, $resp);

  my $keep_alive = _decide_keep_alive($req, \%opt);
  if ($keep_alive) {
    $resp->{_keep_alive}         = 1;
    $resp->{_keep_alive_timeout} = $opt{ka_timeout};
    $resp->{_keep_alive_max}     = $opt{ka_max};
  }

  Iczelia::HTTP::write_response($cli, $resp);
  my $t_done = Time::HiRes::time();

  _log_request(
    $req, $resp,
    {
      handler => $t_handler_end - $t_handler_start,
      cache   => $t_done - $t_handler_end,
      total   => $t_done - $t_handle_start,
      hit     => 0,
    }
  );

  # Analytics runs post-write so failures can't reach the client.
  if ($self->{analytics_db}) {
    eval {
      require Iczelia::Analytics;
      Iczelia::Analytics::log_request($self->{analytics_db}, $req, $resp);
      1;
    } or warn "analytics: $@";
  }

  return $keep_alive ? 'keep' : 'close';
}

# On-the-wire compression for responses the cache hasn't pre-encoded;
# fast brotli quality since this is per request, not the warmer.
my $COMPRESS_CT_RE =
  qr{^(?:text/|application/(?:json|javascript|xml|[\w.+-]+\+xml)\b)}i;
my $COMPRESS_MIN = 256;

sub _compress_uncached {
  my ($req, $resp) = @_;
  return if ($resp->{status} || 200) != 200;
  my $h = $resp->{headers} or return;
  return if exists $h->{'Content-Encoding'};
  my $body = $resp->{body};
  return unless defined $body && length $body;
  return unless ($h->{'Content-Type'} // '') =~ $COMPRESS_CT_RE;

  require Encode;
  $body = Encode::encode('UTF-8', $body) if Encode::is_utf8($body);
  return if length($body) < $COMPRESS_MIN;
  $resp->{body} = $body;    # bytes now; write_response skips re-encoding

  my $ae = lc($req->{headers}{'accept-encoding'} // '');
  my ($enc, $z);
  if ($ae =~ /\bbr\b/) {
    $z = Iczelia::Compress::brotli($body, 5);
    $enc = 'br' if defined $z;
  }
  if (!$enc && $ae =~ /\bgzip\b/) {
    $z = Iczelia::Compress::gzip($body);
    $enc = 'gzip' if defined $z;
  }
  return unless $enc;
  $resp->{body}            = $z;
  $h->{'Content-Encoding'} = $enc;
  $h->{'Vary'} =
    ($h->{'Vary'} && $h->{'Vary'} !~ /\bAccept-Encoding\b/i)
    ? "$h->{'Vary'}, Accept-Encoding"
    : ($h->{'Vary'} || 'Accept-Encoding');
}

# One STDERR line per served request; SLOW marker over $SLOW_REQ_S.
sub _log_request {
  my ($req, $resp, $t) = @_;
  my $total_ms   = int(($t->{total}   // 0) * 1000 + 0.5);
  my $handler_ms = int(($t->{handler} // 0) * 1000 + 0.5);
  my $cache_ms   = int(($t->{cache}   // 0) * 1000 + 0.5);
  my $status     = $resp->{status} // 0;
  my $method     = $req->{method}  // '?';
  my $peer       = $req->{remote}  // '?';
  my $path       = $req->{path}    // '';
  $path =~ tr/\r\n//d;
  if (length $path > 200) {$path = substr($path, 0, 200) . '...'}

  my $slow   = $t->{total} && $t->{total} >= $SLOW_REQ_S;
  my $tag    = $slow     ? 'SLOW ' : '';
  my $marker = $t->{hit} ? ' hit'  : '';

  if ($slow) {
    warn sprintf "[req] %s%s \"%s %s\" %d %dms (handler=%dms cache=%dms)%s\n",
      $tag, $peer, $method, $path, $status,
      $total_ms, $handler_ms, $cache_ms, $marker;
  }
  else {
    warn sprintf "[req] %s \"%s %s\" %d %dms%s\n",
      $peer, $method, $path, $status, $total_ms, $marker;
  }
}

# Per-RFC: HTTP/1.1 keep-alive by default, HTTP/1.0 close by default.
# is_last (per-conn request budget) trumps both.
sub _decide_keep_alive {
  my ($req, $opt) = @_;
  return 0 if $opt->{is_last};
  my $client_conn = lc($req->{headers}{connection} // '');
  if (($req->{proto} // '') eq 'HTTP/1.1') {
    return $client_conn !~ /\bclose\b/;
  }
  return $client_conn =~ /\bkeep-alive\b/ ? 1 : 0;
}

# Cacheable GET/HEAD without a query string and without auth state.
# Returns the path as the cache key, or undef when uncacheable.
sub _cache_key_for {
  my ($self, $req) = @_;
  return undef unless $self->{cache};
  return undef unless $req->{method} eq 'GET' || $req->{method} eq 'HEAD';
  return undef if length($req->{query} // '');
  my $path = $req->{path};
  return undef unless defined $path && length $path;
  return undef if $path =~ m{^/admin/?};
  return undef if $path =~ m{^/login/?$};
  return undef if $path =~ m{^/logout/?$};

  # Home embeds a live GMT clock; caching would freeze it.
  return undef if $path eq '/';

  # Guestbook embeds a per-visitor anon-CSRF token bound to a cookie;
  # caching would leak one user's token to everyone else.
  return undef if $path =~ m{^/guestbook/?$};
  return undef if $req->{cookies} && exists $req->{cookies}{iczelia_sid};
  return $path;
}

sub _peer_addr {
  my ($s) = @_;

  # peerhost() does reverse DNS, which a malicious PTR can stall.
  my $r = eval {
    return 'unix' if $s->isa('IO::Socket::UNIX');
    require Socket;
    my $sa = getpeername($s) or return '?';
    my ($err, $h) = Socket::getnameinfo($sa,
      Socket::NI_NUMERICHOST() | Socket::NI_NUMERICSERV());
    return $err ? '?' : $h;
  };
  return defined $r && length $r ? $r : '?';
}

1;
