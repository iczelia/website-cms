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

package Iczelia::HTTP;
use strict;
use warnings;
use Encode      ();
use Time::HiRes qw();
use Iczelia::Util ();
use Iczelia::Time ();

# HTTP/1.1, one connection at a time. read_request returns a $req
# hashref (method, uri, path, query, proto, headers, cookies,
# qparams, fparams, params, body, uploads, remote) or undef on EOF,
# or { _bad, _why, _status } on a malformed line.

use constant CRLF            => "\015\012";
use constant MAX_LINE        => 8192;
use constant MAX_HDRS        => 100;
use constant DEFAULT_TIMEOUT => 30;           # slowloris guard, seconds
use constant READ_CHUNK      => 8192;

# One state per connection: bytes read past one request's body
# (pipelined / coalesced) survive to the next read_request call.
sub make_state {{buf => ''}}

sub read_request {
  my ($io, %opt) = @_;
  my $cap      = $opt{cap}     // (8 * 1024 * 1024);
  my $timeout  = $opt{timeout} // DEFAULT_TIMEOUT;
  my $state    = $opt{state}   // make_state();
  my $deadline = Time::HiRes::time() + $timeout;

  my $rl = _readline($io, $state, $deadline) or return undef;
  return undef if $rl !~ /\S/;

  my ($method, $uri, $proto) = split /\s+/, $rl, 3;
  return _bad('bad request line')
    unless defined $method && defined $uri && defined $proto;
  return _bad('bad protocol') unless $proto =~ m{^HTTP/1\.[01]$};

  my %hdr;
  my $count = 0;
  while (1) {
    my $line = _readline($io, $state, $deadline);
    defined $line or return _bad('truncated headers');
    last if $line eq '';
    ++$count > MAX_HDRS and return _bad('too many headers');
    if ($line =~ /^[ \t]/) {
      return _bad('header continuation unsupported');
    }
    my ($k, $v) = split /:\s*/, $line, 2;
    defined $v or return _bad("malformed header: $line");
    $k = lc $k;
    if (exists $hdr{$k}) {$hdr{$k} .= ", $v"}
    else                 {$hdr{$k} = $v}
  }

  my ($path, $query) = split /\?/, $uri, 2;
  $query //= '';
  my $req = {
    method  => uc $method,
    uri     => $uri,
    path    => _urldecode($path),
    query   => $query,
    proto   => $proto,
    headers => \%hdr,
    cookies => _parse_cookies($hdr{cookie}),
    qparams => _parse_querystring($query),
    fparams => {},
    params  => undef,
    body    => '',
    uploads => [],
  };

  my $cl = $hdr{'content-length'};
  if (defined $cl) {
    $cl =~ /^\d+$/ or return _bad('bad content-length');
    $cl + 0 > $cap and return _bad('body too large', 413);
    my $body = _read_exact($io, $state, $cl + 0, $deadline);
    defined $body or return _bad('truncated body');
    $req->{body} = $body;
  }
  elsif (($hdr{'transfer-encoding'} // '') =~ /chunked/i) {
    return _bad('chunked transfer not supported', 411);
  }

  my $ct = $hdr{'content-type'} // '';
  if ($ct =~ m{^application/x-www-form-urlencoded}i) {
    $req->{fparams} = _parse_querystring($req->{body});
  }
  elsif ($ct =~ m{^multipart/form-data}i) {
    my ($quoted, $bare) = $ct =~ /boundary=(?:"([^"]+)"|([^;\s]+))/;
    my $boundary = $quoted // $bare;
    $boundary or return _bad('multipart without boundary');
    my $r = _parse_multipart($req->{body}, $boundary);
    $r or return _bad('bad multipart body');
    $req->{fparams} = $r->{fields};
    $req->{uploads} = $r->{uploads};
  }

  $req->{params} = {%{$req->{qparams}}, %{$req->{fparams}}};
  return $req;
}

sub _bad {
  my ($why, $status) = @_;
  return {_bad => 1, _why => $why, _status => $status // 400};
}

sub _readline {
  my ($io, $state, $deadline) = @_;
  while (1) {
    my $idx = index($state->{buf}, CRLF);
    if ($idx >= 0) {
      my $line = substr($state->{buf}, 0, $idx);
      substr($state->{buf}, 0, $idx + 2) = '';
      return $line;
    }
    return undef if length($state->{buf}) >= MAX_LINE;
    return undef unless _wait_readable($io, $deadline);
    my $chunk;
    my $n = sysread($io, $chunk, READ_CHUNK);
    return undef unless $n;
    $state->{buf} .= $chunk;
  }
}

sub _read_exact {
  my ($io, $state, $n, $deadline) = @_;
  while (length($state->{buf}) < $n) {
    return undef unless _wait_readable($io, $deadline);
    my $chunk;
    my $r = sysread($io, $chunk, READ_CHUNK);
    return undef unless $r;
    $state->{buf} .= $chunk;
  }
  my $body = substr($state->{buf}, 0, $n);
  substr($state->{buf}, 0, $n) = '';
  return $body;
}

# True when readable, false on deadline expiry or select() failure.
sub _wait_readable {
  my ($io, $deadline) = @_;
  return 1 unless defined $deadline;
  my $remaining = $deadline - Time::HiRes::time();
  return 0 if $remaining <= 0;
  my $rin = '';
  vec($rin, fileno($io), 1) = 1;
  my $nfound = select(my $rout = $rin, undef, undef, $remaining);
  return $nfound && $nfound > 0;
}

sub _urldecode {
  my $s = shift;
  return '' unless defined $s;
  $s =~ tr/+/ /;
  $s =~ s/%([0-9a-fA-F]{2})/chr(hex($1))/ge;
  return Iczelia::Util::to_utf8($s);
}

sub _parse_querystring {
  my $s = shift;
  my %h;
  return \%h unless defined $s && length $s;
  for my $pair (split /[&;]/, $s) {
    next unless length $pair;
    my ($k, $v) = split /=/, $pair, 2;
    $k = _urldecode($k);
    $v = defined $v ? _urldecode($v) : '';
    if (exists $h{$k}) {
      $h{$k} = [$h{$k}] unless ref $h{$k};
      push @{$h{$k}}, $v;
    }
    else {
      $h{$k} = $v;
    }
  }
  return \%h;
}

sub _parse_cookies {
  my $s = shift;
  my %h;
  return \%h unless defined $s;

  # Cap individual cookie values at 4 KiB to keep an oversized cookie
  # from flowing into Auth's constant-time compares (which scan length).
  for my $part (split /;\s*/, $s) {
    my ($k, $v) = split /=/, $part, 2;
    next unless defined $v;
    $k =~ s/^\s+//;
    $k =~ s/\s+$//;
    $v =~ s/^\s+//;
    $v =~ s/\s+$//;
    $v =~ s/^"(.*)"$/$1/;
    next if length($v) > 4096;
    $h{$k} = $v;
  }
  return \%h;
}

sub _parse_multipart {
  my ($body, $boundary) = @_;
  my $sep = "--$boundary";
  my $end = "--$boundary--";

  # Find the next boundary occurrence that's at start-of-body or
  # preceded by CRLF, per RFC 2046. Without this, an attacker could
  # smuggle a fake boundary inside a field value.
  my $find = sub {
    my ($from) = @_;
    my $p = $from;
    while (($p = index($body, $sep, $p)) >= 0) {
      return $p if $p == 0 || substr($body, $p - 2, 2) eq CRLF;
      $p++;
    }
    return -1;
  };

  my @parts;
  my $start = $find->(0);
  return undef if $start < 0;
  $start += length($sep);
  $start += 2 if substr($body, $start, 2) eq CRLF;

  while (1) {
    my $next = $find->($start);
    return undef if $next < 0;
    my $chunk = substr($body, $start, $next - $start);
    $chunk =~ s/\015\012\z//;
    push @parts, $chunk;
    $start = $next + length($sep);
    last if substr($body, $next, length($end)) eq $end;
    $start += 2 if substr($body, $start, 2) eq CRLF;
  }

  my %fields;
  my @uploads;
  for my $p (@parts) {
    my ($hdr, $body2) = split /\015\012\015\012/, $p, 2;
    next unless defined $body2;
    my %h;
    for my $line (split /\015\012/, $hdr) {
      my ($k, $v) = split /:\s*/, $line, 2;
      $h{lc $k} = $v if defined $v;
    }
    my $cd         = $h{'content-disposition'} || '';
    my ($name)     = $cd =~ /name="([^"]*)"/;
    my ($filename) = $cd =~ /filename="([^"]*)"/;
    next unless defined $name;
    $name = Iczelia::Util::to_utf8($name);
    if (defined $filename) {
      push @uploads,
        {
        name         => $name,
        filename     => Iczelia::Util::to_utf8($filename),
        content_type => $h{'content-type'} // 'application/octet-stream',
        body         => $body2,
        size         => length $body2,
        };
    }
    else {
      $fields{$name} = Iczelia::Util::to_utf8($body2);
    }
  }
  return {fields => \%fields, uploads => \@uploads};
}

my %STATUS_TEXT = (
  200 => 'OK',
  201 => 'Created',
  204 => 'No Content',
  301 => 'Moved Permanently',
  302 => 'Found',
  303 => 'See Other',
  304 => 'Not Modified',
  400 => 'Bad Request',
  401 => 'Unauthorized',
  403 => 'Forbidden',
  404 => 'Not Found',
  405 => 'Method Not Allowed',
  409 => 'Conflict',
  411 => 'Length Required',
  413 => 'Payload Too Large',
  414 => 'URI Too Long',
  415 => 'Unsupported Media Type',
  422 => 'Unprocessable Entity',
  429 => 'Too Many Requests',
  500 => 'Internal Server Error',
  501 => 'Not Implemented',
  503 => 'Service Unavailable',
);

sub write_response {
  my ($io, $resp) = @_;
  my $status = $resp->{status}       || 200;
  my $text   = $STATUS_TEXT{$status} || 'OK';
  my $body   = $resp->{body};
  $body = '' unless defined $body;
  if (Encode::is_utf8($body)) {
    $body = Encode::encode('UTF-8', $body);
  }

  my $hdrs = $resp->{headers} || {};
  $hdrs->{'Content-Length'} = length $body;
  $hdrs->{'Content-Type'} //= 'text/html; charset=utf-8';
  $hdrs->{'Date'}         //= Iczelia::Time::http_date();
  if ($resp->{_keep_alive}) {
    $hdrs->{'Connection'} //= 'keep-alive';
    $hdrs->{'Keep-Alive'} //=
      "timeout=$resp->{_keep_alive_timeout}, max=$resp->{_keep_alive_max}"
      if $resp->{_keep_alive_timeout} && $resp->{_keep_alive_max};
  }
  else {
    $hdrs->{'Connection'} //= 'close';
  }
  $hdrs->{'Server'} //= 'iczelia/0.1';

  my $head = "HTTP/1.1 $status $text" . CRLF;
  for my $k (sort keys %$hdrs) {
    my $v  = $hdrs->{$k};
    my $sk = _strip_crlf($k);
    if (ref $v eq 'ARRAY') {
      $head .= "$sk: " . _strip_crlf($_) . CRLF for @$v;
    }
    else {
      $head .= "$sk: " . _strip_crlf($v) . CRLF;
    }
  }
  if (my $cookies = $resp->{cookies}) {
    for my $c (@$cookies) {
      $head .= 'Set-Cookie: ' . _strip_crlf($c) . CRLF;
    }
  }
  $head .= CRLF;

  print $io $head;
  print $io $body unless ($resp->{method_was} || '') eq 'HEAD';
}

# Defense against header injection via tainted redirect URLs / cookies.
sub _strip_crlf {
  my $s = shift;
  return '' unless defined $s;
  $s =~ tr/\r\n//d;
  $s;
}

sub is_https {
  my ($req) = @_;
  return 0 unless $req && ref($req) eq 'HASH';
  my $proto = $req->{headers}{'x-forwarded-proto'} // '';
  return $proto =~ /^https$/i ? 1 : 0;
}

sub make_cookie {
  my (%c)   = @_;
  my $name  = _strip_crlf($c{name});
  my $value = _strip_crlf($c{value});
  my $s     = "$name=$value";
  $s .= "; Path=" . _strip_crlf($c{path})         if $c{path};
  $s .= "; Domain=" . _strip_crlf($c{domain})     if $c{domain};
  $s .= "; Max-Age=" . _strip_crlf($c{max_age})   if defined $c{max_age};
  $s .= "; Expires=" . _strip_crlf($c{expires})   if $c{expires};
  $s .= '; HttpOnly'                              if $c{httponly};
  $s .= '; Secure'                                if $c{secure};
  $s .= "; SameSite=" . _strip_crlf($c{samesite}) if $c{samesite};
  return $s;
}

sub redirect {
  my ($url, %opt) = @_;
  my $status = $opt{status} || 303;
  my $safe   = _strip_crlf($url);
  return {
    status  => $status,
    headers =>
      {Location => $safe, 'Content-Type' => 'text/plain; charset=utf-8'},
    body => "Redirecting to $safe\n",
  };
}

sub text {
  my ($body, %opt) = @_;
  return {
    status  => $opt{status} || 200,
    headers => {'Content-Type' => 'text/plain; charset=utf-8'},
    body    => $body,
  };
}

sub html {
  my ($body, %opt) = @_;
  my $headers = $opt{headers} || {};
  $headers->{'Content-Type'} = 'text/html; charset=utf-8';
  return {
    status  => $opt{status} || 200,
    headers => $headers,
    body    => $body,
  };
}

sub json {
  my ($data, %opt) = @_;
  require JSON::PP;
  return {
    status  => $opt{status} || 200,
    headers => {
      'Content-Type'  => 'application/json; charset=utf-8',
      'Cache-Control' => 'no-store',
    },
    body => JSON::PP->new->utf8(0)->canonical(1)->encode($data),
  };
}

sub error {
  my ($status, $msg) = @_;
  return {
    status  => $status,
    headers => {'Content-Type' => 'text/plain; charset=utf-8'},
    body    => ($STATUS_TEXT{$status} || 'Error') . ($msg ? ": $msg\n" : "\n"),
  };
}

1;
