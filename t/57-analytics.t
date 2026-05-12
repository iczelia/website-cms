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

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Analytics;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/test.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

# 1. UA classification.
is(Iczelia::Analytics::_ua_class('Mozilla/5.0'),               'browser');
is(Iczelia::Analytics::_ua_class('Mozilla/5.0 (iPhone; CPU)'), 'mobile');
is(Iczelia::Analytics::_ua_class('Googlebot/2.1'),             'bot');
is(Iczelia::Analytics::_ua_class('curl/8.0'),                  'bot');
is(Iczelia::Analytics::_ua_class(''),                          'other');

# 2. Log a few requests.
for my $p (qw(/blog/foo/ /blog/bar/ /blog/foo/)) {
  my $req = {
    path    => $p,
    method  => 'GET',
    remote  => '198.51.100.7',
    headers => {'user-agent' => 'Mozilla/5.0'},
  };
  Iczelia::Analytics::log_request($db, $req, {status => 200});
}
Iczelia::Analytics::flush($db);
my $n = $db->one('SELECT COUNT(*) FROM analytics_events');
is($n, 3, 'three events logged');

# 3. Skipped paths don't get logged.
Iczelia::Analytics::log_request(
  $db,
  {
    path    => '/healthz',
    method  => 'GET',
    remote  => 'x',
    headers => {},
  },
  {status => 200}
);
Iczelia::Analytics::log_request(
  $db,
  {
    path    => '/admin/foo',
    method  => 'GET',
    remote  => 'x',
    headers => {},
  },
  {status => 200}
);
Iczelia::Analytics::log_request(
  $db,
  {
    path    => '/cms.css',
    method  => 'GET',
    remote  => 'x',
    headers => {},
  },
  {status => 200}
);
Iczelia::Analytics::flush($db);
$n = $db->one('SELECT COUNT(*) FROM analytics_events');
is($n, 3, 'admin/healthz/static skipped');

# 4. Aggregator. We need events older than today for the rollup to fire,
# so push them back manually.
$db->do_("UPDATE analytics_events SET ts = ts - 86400");
Iczelia::Analytics::aggregate_due($db);
my $rows = $db->all('SELECT * FROM analytics_daily ORDER BY path');
is(scalar(@$rows), 2, 'two distinct paths in daily roll-up');
my %by_path = map {$_->{path} => $_} @$rows;
is($by_path{'/blog/foo/'}{views}, 2, 'foo got 2 views');
is($by_path{'/blog/bar/'}{views}, 1, 'bar got 1 view');

# Events older than the cutoff have been deleted.
my $remaining = $db->one('SELECT COUNT(*) FROM analytics_events');
is($remaining, 0, 'old events trimmed');

# 5. Dashboard data.
my $d = Iczelia::Analytics::dashboard_data($db, range => 'all');
is($d->{totals}{views}, 3, 'totals.views = 3');
ok(scalar(@{$d->{top_paths}}) >= 2, 'top_paths populated');

# 6. Bar SVG.
my $svg = Iczelia::Analytics::render_bars_svg($d->{days}, column => 'views');
like($svg, qr/<svg/,  'svg rendered');
like($svg, qr/<rect/, 'svg has bars');

done_testing;
