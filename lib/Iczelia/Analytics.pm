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
use Iczelia::UA ();

# visitor_hash = sha256(ip|ua|daily_salt)[0..15]. Salt rotates at
# UTC midnight; raw IP/UA never lands in the DB.

# Aggregate at most once per worker per AGG_INTERVAL seconds. Time-
# based instead of event-counting so a 4-worker prefork doesn't fire
# 4x more often than intended.
our $AGG_INTERVAL = 60;

my $LAST_AGG_AT = 0;

# Asset / second-fetch paths that drown out real pageviews in the
# "most common destinations" chart. Concatenated as a literal AND
# fragment into the top_paths SELECT; covers everything served by
# Iczelia::Handlers::Static plus the well-known crawler files.
# Keep this list in sync with Static.pm's route map.
sub ASSET_FILTER {
  return q{
    AND path NOT LIKE '/vendor/%'
    AND path NOT LIKE '/fonts/%'
    AND path NOT LIKE '/assets-%'
    AND path NOT LIKE '/cms-icons/%'
    AND path NOT LIKE '/cms-%'
    AND path NOT LIKE '/cms.%'
    AND path NOT LIKE '/media/%'
    AND path NOT LIKE '/og/%'
    AND path NOT LIKE '/style.%'
    AND path NOT LIKE '/about.compat.css'
    AND path NOT LIKE '/common.compat.css'
    AND path NOT IN ('/favicon.ico', '/robots.txt', '/sitemap.xml',
                     '/feed.xml',   '/index.xml',  '/rss.xml',
                     '/pub.pgp')
  };
}

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
                        referer_host, ua_class, browser, os, device,
                        bot_ua)
                    VALUES(?,?,?,?,?,?,?,?,?,?,?)}, @$r
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
  my $u    = Iczelia::UA::parse($ua);
  push @BUFFER,
    [
    time,                   $path,
    $resp->{status} // 200, $req->{method} // 'GET',
    $vh,                    _referer_host($req),
    $u->{ua_class},         $u->{browser},
    $u->{os},               $u->{device},
    $u->{bot_ua},
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
      for my $k (
        ['browser', 'browser'], ['os', 'os'],
        ['device',  'device'],  ['bot', 'bot_ua'],
        )
      {
        my ($kind, $col) = @$k;
        $d->do_(
          qq{
            INSERT INTO analytics_ua(date, kind, label, count)
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch'),
                   '$kind', $col, COUNT(*)
              FROM analytics_events
             WHERE ts < ? AND $col IS NOT NULL AND $col <> ''
             GROUP BY 1, 3
            ON CONFLICT(date, kind, label) DO UPDATE SET
              count = analytics_ua.count + excluded.count
        }, $cutoff
        );
      }
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

  # Compute the date boundary in SQLite, bind everywhere else.
  my $start = $db->one(
    q{SELECT CASE
        WHEN ? = '7d'  THEN date('now','-6 days')
        WHEN ? = '30d' THEN date('now','-29 days')
        ELSE '1970-01-01'
      END}, $range, $range
  );

  my $rows = $db->all(
    q{SELECT date,
             SUM(views)   AS views,
             SUM(uniques) AS uniques,
             SUM(bots)    AS bots
        FROM analytics_daily
       WHERE date >= ?
       GROUP BY date
       ORDER BY date}, $start
  );
  # The "order by" column can't be bound; pick the SQL at the Perl level.
  # ASSET_FILTER excludes static-file routes (CSS, JS, fonts, image
  # packs, media uploads, favicons, sitemap, robots) from "most common
  # destinations" -- those numbers are dominated by browser secondary
  # fetches and drown out the actual pageviews the dashboard is for.
  my $top_paths = $exclude_bots
    ? $db->all(
      qq{SELECT path,
               SUM(views)   AS views,
               SUM(uniques) AS uniques,
               SUM(bots)    AS bots
          FROM analytics_daily
         WHERE date >= ? @{[ ASSET_FILTER() ]}
         GROUP BY path
         ORDER BY (SUM(views) - SUM(bots)) DESC
         LIMIT 20}, $start
    )
    : $db->all(
      qq{SELECT path,
               SUM(views)   AS views,
               SUM(uniques) AS uniques,
               SUM(bots)    AS bots
          FROM analytics_daily
         WHERE date >= ? @{[ ASSET_FILTER() ]}
         GROUP BY path
         ORDER BY SUM(views) DESC
         LIMIT 20}, $start
    );
  my $top_refs = $db->all(
    q{SELECT referer_host AS host, SUM(count) AS count
        FROM analytics_referrers
       WHERE date >= ?
       GROUP BY referer_host
       ORDER BY count DESC LIMIT 20}, $start
  );
  my $totals = $db->row(
    q{SELECT SUM(views) AS views, SUM(uniques) AS uniques, SUM(bots) AS bots
        FROM analytics_daily WHERE date >= ?}, $start
  ) || {views => 0, uniques => 0, bots => 0};
  $_ //= 0 for @{$totals}{qw(views uniques bots)};

  my %ua;
  for my $kind (qw(browser os device bot)) {
    $ua{$kind} = $db->all(
      q{SELECT label, SUM(count) AS count
          FROM analytics_ua
         WHERE date >= ? AND kind = ?
         GROUP BY label
         ORDER BY count DESC LIMIT 30}, $start, $kind
    );
  }

  return {
    range       => $range,
    bots_hidden => $exclude_bots,
    days        => $rows,
    top_paths   => $top_paths,
    top_refs    => $top_refs,
    totals      => $totals,
    ua          => {
      browsers => $ua{browser},
      os       => $ua{os},
      devices  => $ua{device},
      bots     => $ua{bot},
    },
  };
}

1;
