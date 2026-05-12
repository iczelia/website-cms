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

package Iczelia::Fetcher;
use strict;
use warnings;
use Carp       qw(croak);
use JSON::PP   ();
use IPC::Open3 ();
use Symbol     qw(gensym);

# Pulls public events from GitHub/Mastodon/Bluesky into `activity`.
# Cron-driven and admin-triggerable; HTTP via curl so TLS stays out of
# Perl. run_all/run() return [{source,status,count,error?}, ...].

my $JSON = JSON::PP->new->utf8(0);

sub new {
  my ($class, %arg) = @_;
  croak "db required"     unless $arg{db};
  croak "render required" unless $arg{render};
  return bless {
    db         => $arg{db},
    render     => $arg{render},
    curl       => $arg{curl}       || 'curl',
    timeout_s  => $arg{timeout_s}  || 10,
    max_bytes  => $arg{max_bytes}  || 1 * 1024 * 1024,
    user_agent => $arg{user_agent} || ($arg{db}->setting('fetcher.user_agent')
      || 'iczelia.net-fetcher/1.0 (+https://iczelia.net)'),
  }, $class;
}

sub run_all {
  my ($self) = @_;
  my @results;
  push @results, $self->run('github');
  push @results, $self->run('mastodon');
  push @results, $self->run('bluesky');
  if (grep {$_->{status} eq 'ok' && $_->{count} > 0} @results) {
    $self->{render}->invalidate_home;
  }
  return \@results;
}

sub run {
  my ($self, $source) = @_;
  my $method = "_fetch_$source";
  return {source => $source, status => 'unsupported', count => 0}
    unless $self->can($method);
  my @rows;
  my $err;
  eval {@rows = $self->$method; 1} or $err = $@ || 'unknown';
  if ($err) {
    warn "[fetcher] $source: $err\n";
    return {
      source => $source,
      status => 'error',
      count  => 0,
      error  => $err
    };
  }
  return {
    source => $source,
    status => 'ok',
    count  => 0,
    error  => 'no rows'
    }
    unless @rows;
  $self->_replace_source($source, \@rows);
  return {source => $source, status => 'ok', count => scalar @rows};
}

sub _replace_source {
  my ($self, $source, $rows) = @_;
  my $now = time;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM activity WHERE source=?', $source);
      my $pos = 0;
      for my $r (@$rows) {

        # No `javascript:` smuggled into a rendered href.
        my $url = $r->{url};
        $url = undef unless defined $url && $url =~ m{^https?://}i;
        $d->do_(
          q{INSERT INTO activity(source, text, url, posted_at, position, fetched_at)
                      VALUES(?,?,?,?,?,?)},
          $source, $r->{text}, $url, $r->{posted_at}, $pos++, $now
        );
      }
    }
  );
}

# Reject file:// / scheme-less so a stray setting can't make curl
# read local files.
sub _ok_remote_url {
  my $u = shift;
  return 0 unless defined $u && length $u;
  return 0 unless $u =~ m{^https?://[^\s/]+}i;
  return 1;
}

sub _curl {
  my ($self, $url) = @_;
  my @cmd = (
    $self->{curl},       '--silent',
    '--show-error',      '--max-time',
    $self->{timeout_s},  '--max-filesize',
    $self->{max_bytes},  '--user-agent',
    $self->{user_agent}, '--',
    $url,
  );
  my ($wr, $rd, $er);
  $er = gensym;
  my $pid = IPC::Open3::open3($wr, $rd, $er, @cmd);
  close $wr;
  binmode $rd;
  binmode $er;
  local $/;
  my $body   = <$rd>;
  my $stderr = <$er>;
  close $rd;
  close $er;
  waitpid $pid, 0;
  my $rc = $?;

  if ($rc != 0) {
    my $msg = $stderr // '';
    chomp $msg;
    die "curl: $url: rc=" . ($rc >> 8) . ($msg ? ": $msg" : '');
  }
  return $body // '';
}

sub _fetch_github {
  my ($self) = @_;
  my $user = $self->{db}->setting('github.username');
  return () unless $user;
  return () unless $user =~ /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$/;
  my $url    = "https://api.github.com/users/$user/events/public";
  my $body   = $self->_curl($url);
  my $events = eval {$JSON->decode($body)};
  return () unless ref $events eq 'ARRAY';

  # One API page (~30 events); the renderer collapses repeats so a
  # wider sample wins when one repo dominates the feed.
  my @rows;
  for my $e (@$events) {
    my $r = _gh_map($e);
    next unless $r;
    push @rows, $r;
    last if @rows >= 30;
  }
  return @rows;
}

sub _gh_map {
  my ($e)  = @_;
  my $type = $e->{type}       // '';
  my $repo = $e->{repo}{name} // '?';
  my $when = _parse_iso($e->{created_at});
  my $base = "https://github.com/$repo";
  return _gh_pushed_to($repo, $base, $when, $e) if $type eq 'PushEvent';
  return _gh_pr($repo, $base, $when, $e)        if $type eq 'PullRequestEvent';
  return _gh_issue($repo, $base, $when, $e)     if $type eq 'IssuesEvent';
  return _gh_starred($repo, $base, $when)       if $type eq 'WatchEvent';
  return _gh_create($repo, $base, $when, $e)    if $type eq 'CreateEvent';
  return _gh_release($repo, $base, $when, $e)   if $type eq 'ReleaseEvent';
  return undef;
}

sub _gh_pushed_to {
  my ($repo, $base, $when, $e) = @_;
  my $sha;
  if (ref $e->{payload}{commits} eq 'ARRAY' && @{$e->{payload}{commits}}) {
    $sha = $e->{payload}{commits}[-1]{sha};
  }
  my $url = $sha ? "$base/commit/$sha" : $base;
  return {text => "pushed to $repo", url => $url, posted_at => $when};
}

sub _gh_pr {
  my ($repo, $base, $when, $e) = @_;
  my $action = $e->{payload}{action} // '';
  return undef unless $action eq 'opened' || $action eq 'reopened';
  my $num = $e->{payload}{pull_request}{number} // 0;
  return {
    text      => "opened pr in $repo",
    url       => $num ? "$base/pull/$num" : $base,
    posted_at => $when,
  };
}

sub _gh_issue {
  my ($repo, $base, $when, $e) = @_;
  my $action = $e->{payload}{action} // '';
  return undef unless $action eq 'opened';
  my $num = $e->{payload}{issue}{number} // 0;
  return {
    text      => "opened issue in $repo",
    url       => $num ? "$base/issues/$num" : $base,
    posted_at => $when,
  };
}

sub _gh_starred {
  my ($repo, $base, $when) = @_;
  return {text => "starred $repo", url => $base, posted_at => $when};
}

sub _gh_create {
  my ($repo, $base, $when, $e) = @_;
  my $kind = $e->{payload}{ref_type} // '';
  return undef if $kind eq 'branch';
  my $ref = $e->{payload}{ref} // '';
  my $text =
      $kind eq 'tag'        ? "tagged $ref in $repo"
    : $kind eq 'repository' ? "created repo $repo"
    :                         "created $kind in $repo";
  return {text => $text, url => $base, posted_at => $when};
}

sub _gh_release {
  my ($repo, $base, $when, $e) = @_;
  return undef unless ($e->{payload}{action} // '') eq 'published';
  my $tag = $e->{payload}{release}{tag_name} // '';
  return {
    text      => "released $tag in $repo",
    url       => $tag ? "$base/releases/tag/$tag" : "$base/releases",
    posted_at => $when,
  };
}

sub _fetch_mastodon {
  my ($self) = @_;
  my $url = $self->{db}->setting('mastodon.feed_url');
  return () unless _ok_remote_url($url);
  my $body = $self->_curl($url);
  return () unless $body =~ /<item/;

  my @items;
  while ($body =~ m{<item>(.*?)</item>}gs) {
    last if @items >= 3;
    my $item    = $1;
    my ($title) = $item =~ m{<title>(.*?)</title>}s;
    my ($link)  = $item =~ m{<link>(.*?)</link>}s;
    my ($pub)   = $item =~ m{<pubDate>(.*?)</pubDate>}s;
    $title = _strip_cdata($title // '');
    $link  = _strip_cdata($link  // '');
    my $when  = _parse_rfc2822($pub);
    my $short = _excerpt($title, 60);
    push @items,
      {
      text      => length $short ? "last post: $short" : 'last post',
      url       => $link,
      posted_at => $when,
      };
  }
  return @items;
}

sub _strip_cdata {
  my $s = shift;
  $s =~ s/<!\[CDATA\[(.*?)\]\]>/$1/gs;
  $s =~ s/^\s+//;
  $s =~ s/\s+$//;

  # Mastodon's RSS wraps body text in <p>, <a>, etc.; strip them.
  $s =~ s/<[^>]+>//g;
  $s =~ s/&amp;/&/g;
  $s =~ s/&lt;/</g;
  $s =~ s/&gt;/>/g;
  $s =~ s/&quot;/"/g;
  $s =~ s/&#39;/'/g;
  return $s;
}

sub _fetch_bluesky {
  my ($self) = @_;
  my $handle = $self->{db}->setting('bluesky.handle');
  return () unless $handle;

  # Handles are DNS-style: letters, digits, dots, dashes.
  return () unless $handle =~ /^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,253})$/;
  my $url =
    "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor=$handle&limit=10";
  my $body = $self->_curl($url);
  my $obj  = eval {$JSON->decode($body)};
  return () unless ref($obj) eq 'HASH' && ref($obj->{feed}) eq 'ARRAY';

  my $profile_url = "https://bsky.app/profile/$handle";

  my @rows;
  for my $f (@{$obj->{feed}}) {
    last if @rows >= 3;
    my $post = $f->{post} or next;
    next if $post->{record}{reply};
    my $text  = $post->{record}{text} // '';
    my $when  = _parse_iso($post->{indexedAt} // $post->{record}{createdAt});
    my $short = _excerpt($text, 60);
    my $rkey;
    if ($post->{uri} && $post->{uri} =~ m{/app\.bsky\.feed\.post/([^/]+)$}) {
      $rkey = $1;
    }
    my $url = $rkey ? "$profile_url/post/$rkey" : $profile_url;
    push @rows,
      {
      text      => length $short ? "last post: $short" : 'last post',
      url       => $url,
      posted_at => $when,
      };
  }
  return @rows;
}

sub _excerpt {
  my ($s, $n) = @_;
  return '' unless defined $s;
  $s =~ s/\s+/ /g;
  $s =~ s/^\s+//;
  $s =~ s/\s+$//;
  if (length $s > $n) {
    $s = substr($s, 0, $n);
    $s =~ s/\s+\S*$//;
    $s .= '...';
  }
  return $s;
}

# Parse ISO-8601 like 2026-04-21T10:11:12Z (lenient on separators).
sub _parse_iso {
  my $s = shift;
  return undef unless defined $s;
  if ($s =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})/) {
    require Time::Local;
    return Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1);
  }
  return undef;
}

# Parse RFC 2822 dates like "Mon, 21 Apr 2026 10:11:12 +0000".
my %MON = (
  Jan => 0,
  Feb => 1,
  Mar => 2,
  Apr => 3,
  May => 4,
  Jun => 5,
  Jul => 6,
  Aug => 7,
  Sep => 8,
  Oct => 9,
  Nov => 10,
  Dec => 11
);

sub _parse_rfc2822 {
  my $s = shift;
  return undef unless defined $s;
  if ($s =~ /^\s*(?:\w+,\s*)?(\d+)\s+(\w+)\s+(\d+)\s+(\d+):(\d+):(\d+)/) {
    require Time::Local;
    my $mon = $MON{ucfirst lc $2};
    return undef unless defined $mon;
    return Time::Local::timegm($6, $5, $4, $1, $mon, $3);
  }
  return undef;
}

1;
