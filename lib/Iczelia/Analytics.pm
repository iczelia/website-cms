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

package Iczelia::Analytics;
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

# visitor_hash = sha256(ip|ua|daily_salt)[0..15]. Salt rotates at
# UTC midnight; raw IP/UA never lands in the DB.

# Aggregate at most once per worker per AGG_INTERVAL seconds. Time-
# based instead of event-counting so a 4-worker prefork doesn't fire
# 4x more often than intended.
our $AGG_INTERVAL = 60;

my $LAST_AGG_AT = 0;

# Stored-secret-derived so every preforked worker hashes alike;
# otherwise daily-uniques inflate across worker boundaries.
sub _daily_salt {
  my ($db) = @_;
  my @t    = gmtime(time);
  my $day  = sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
  my $secret =
    $db
    ? ($db->setting('analytics.salt_secret') // _seed_secret($db))
    : 'fallback';
  return sha256_hex("$secret|$day");
}

# Mint and persist on first use; future workers read it from settings.
sub _seed_secret {
  my ($db) = @_;
  my $rnd = '';
  if (open my $fh, '<:raw', '/dev/urandom') {
    sysread $fh, $rnd, 32;
    close $fh;
  }
  my $hex = unpack 'H*', $rnd;
  $hex = sha256_hex(time . $$) unless length $hex;
  eval {$db->set_setting('analytics.salt_secret', $hex)};
  return $hex;
}

sub _ua_class {
  my ($ua) = @_;
  $ua = lc($ua // '');
  return 'other' unless length $ua;
  return 'bot'
    if $ua =~
    /(?:bot|crawler|spider|scrap|fetch|monitor|preview|headless|httpclient|python-requests|libwww|curl|wget)/;
  return 'mobile'
    if $ua =~ /(?:android|iphone|ipad|mobile)/;
  return 'browser';
}

sub _referer_host {
  my ($req) = @_;
  my $ref = $req->{headers}{'referer'} // $req->{headers}{'referrer'};
  return undef unless defined $ref && length $ref;
  return undef unless $ref =~ m{^https?://([^/?#]+)};
  my $host = lc $1;
  $host =~ s/^www\.//;
  return $host;
}

# Per-worker buffer; flushed when full or stale. Drops on worker death,
# acceptable for analytics. Holds the request-time `ts` so flush ordering
# doesn't smear timestamps.
our $BUFFER_MAX      = 50;
our $BUFFER_INTERVAL = 5;
my @BUFFER;
my $BUFFER_AT = 0;

sub flush {
  my ($db) = @_;
  return unless @BUFFER;
  my $rows = [@BUFFER];
  @BUFFER    = ();
  $BUFFER_AT = time;
  eval {
    $db->tx(
      sub {
        my $d = shift;
        for my $r (@$rows) {
          $d->do_(
            q{
                    INSERT INTO analytics_events(
                        ts, path, status, method, visitor_hash,
                        referer_host, ua_class)
                    VALUES(?,?,?,?,?,?,?)}, @$r
          );
        }
      }
    );
    1;
  } or warn "analytics flush: $@";
}

sub log_request {
  my ($db, $req, $resp) = @_;
  return unless $db;
  return unless $req && $req->{path};
  my $path = $req->{path};
  return if $path eq '/healthz';
  return if $path =~ m{^/admin/};
  return if $path =~ m{\.(?:png|jpe?g|gif|webp|svg|ico|css|js|woff2?)\z};
  my $ip   = $req->{remote}                // '';
  my $ua   = $req->{headers}{'user-agent'} // '';
  my $salt = _daily_salt($db);
  my $vh   = substr(sha256_hex("$ip|$ua|$salt"), 0, 16);
  push @BUFFER,
    [
    time,                   $path,
    $resp->{status} // 200, $req->{method} // 'GET',
    $vh,                    _referer_host($req),
    _ua_class($ua),
    ];
  my $now = time;

  if ( @BUFFER >= $BUFFER_MAX
    || $now - $BUFFER_AT >= $BUFFER_INTERVAL)
  {
    flush($db);
  }
  if ($now - $LAST_AGG_AT >= $AGG_INTERVAL) {
    $LAST_AGG_AT = $now;
    eval {aggregate_due($db); 1} or warn "analytics agg: $@";
  }
}

# Roll yesterday's events into the daily/referrer rollups. Idempotent
# (PK + sum-on-conflict). Trims the events table back to 250k.
sub aggregate_due {
  my ($db) = @_;
  return unless $db;
  flush($db);    # roll buffered events into the table first
  $db->tx(
    sub {
      my $d      = shift;
      my $cutoff = $d->one(q{SELECT strftime('%s','now','start of day')});
      $d->do_(
        q{
            INSERT INTO analytics_daily(date, path, views, uniques, bots)
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch'),
                   path,
                   COUNT(*),
                   COUNT(DISTINCT visitor_hash),
                   SUM(CASE WHEN ua_class='bot' THEN 1 ELSE 0 END)
              FROM analytics_events
             WHERE ts < ?
             GROUP BY 1, 2
            ON CONFLICT(date, path) DO UPDATE SET
              views   = analytics_daily.views   + excluded.views,
              uniques = analytics_daily.uniques + excluded.uniques,
              bots    = analytics_daily.bots    + excluded.bots
        }, $cutoff
      );
      $d->do_(
        q{
            INSERT INTO analytics_referrers(date, referer_host, count)
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch'),
                   referer_host, COUNT(*)
              FROM analytics_events
             WHERE ts < ? AND referer_host IS NOT NULL
             GROUP BY 1, 2
            ON CONFLICT(date, referer_host) DO UPDATE SET
              count = analytics_referrers.count + excluded.count
        }, $cutoff
      );
      $d->do_('DELETE FROM analytics_events WHERE ts < ?', $cutoff);
    }
  );
  my $n = $db->one('SELECT COUNT(*) FROM analytics_events') // 0;
  if ($n > 250_000) {
    my $trim = $n - 250_000;
    $db->do_(
      q{
            DELETE FROM analytics_events WHERE id IN (
              SELECT id FROM analytics_events ORDER BY ts ASC LIMIT ?
            )}, $trim
    );
  }
}

# Build the dashboard data structure. Range is one of '7d', '30d', 'all'.
sub dashboard_data {
  my ($db, %opt) = @_;
  my $range        = $opt{range} || '7d';
  my $exclude_bots = $opt{bots} && $opt{bots} eq 'hide' ? 1 : 0;

  # Flush pending events first so live-day numbers are reasonable.
  aggregate_due($db);

  my $start;
  if    ($range eq '7d')  {$start = "date('now','-6 days')"}
  elsif ($range eq '30d') {$start = "date('now','-29 days')"}
  else                    {$start = "'1970-01-01'"}

  my $bot_clause = $exclude_bots ? "(views - bots)" : "views";
  my $rows       = $db->all(
    qq{
        SELECT date,
               SUM(views)   AS views,
               SUM(uniques) AS uniques,
               SUM(bots)    AS bots
          FROM analytics_daily
         WHERE date >= $start
         GROUP BY date
         ORDER BY date
    }
  );
  my $top_paths = $db->all(
    qq{
        SELECT path,
               SUM(views)   AS views,
               SUM(uniques) AS uniques,
               SUM(bots)    AS bots
          FROM analytics_daily
         WHERE date >= $start
         GROUP BY path
         ORDER BY $bot_clause DESC
         LIMIT 20
    }
  );
  my $top_refs = $db->all(
    qq{
        SELECT referer_host AS host, SUM(count) AS count
          FROM analytics_referrers
         WHERE date >= $start
         GROUP BY referer_host
         ORDER BY count DESC LIMIT 20
    }
  );
  my $totals = $db->row(
    qq{
        SELECT SUM(views) AS views, SUM(uniques) AS uniques, SUM(bots) AS bots
          FROM analytics_daily WHERE date >= $start
    }
  ) || {views => 0, uniques => 0, bots => 0};
  return {
    range       => $range,
    bots_hidden => $exclude_bots,
    days        => $rows,
    top_paths   => $top_paths,
    top_refs    => $top_refs,
    totals      => $totals,
  };
}

# Inline SVG bar chart - returns an HTML string with no JS.
sub render_bars_svg {
  my ($rows, %opt) = @_;
  my $w   = $opt{width}  || 720;
  my $h   = $opt{height} || 200;
  my $pad = 20;
  my $n   = scalar @$rows;
  return '<p>(no data)</p>' unless $n;
  my $col = $opt{column} || 'views';
  my $max = 0;
  for my $r (@$rows) {$max = $r->{$col} if $r->{$col} > $max}
  $max = 1 if $max <= 0;
  my $bw    = ($w - 2 * $pad) / $n;
  my @parts = (
    qq{<svg class="cms-chart" viewBox="0 0 $w $h" preserveAspectRatio="none" xmlns="http://www.w3.org/2000/svg">},
  );
  my $i = 0;

  for my $r (@$rows) {
    my $v  = $r->{$col};
    my $bh = ($h - 2 * $pad) * ($v / $max);
    my $x  = sprintf '%.1f', $pad + $bw * $i;
    my $y  = sprintf '%.1f', $h - $pad - $bh;
    my $bb = sprintf '%.1f', $bw * 0.85;
    $bh = sprintf '%.1f', $bh;
    push @parts,
      qq{<rect x="$x" y="$y" width="$bb" height="$bh" fill="#4a6da7"><title>$r->{date}: $v</title></rect>};
    $i++;
  }
  push @parts,
    qq{<line x1="$pad" y1="@{[$h-$pad]}" x2="@{[$w-$pad]}" y2="@{[$h-$pad]}" stroke="#888"/>};
  push @parts, qq{</svg>};
  return join '', @parts;
}

1;
