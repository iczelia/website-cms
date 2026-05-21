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

my $FIREFOX =
  'Mozilla/5.0 (X11; Linux x86_64; rv:121.0) Gecko/20100101 Firefox/121.0';
my $GOOGLEBOT =
  'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)';

# 1. Log human + bot requests.
for my $p (qw(/blog/foo/ /blog/bar/ /blog/foo/)) {
  Iczelia::Analytics::log_request(
    $db,
    {
      path    => $p,
      method  => 'GET',
      remote  => '198.51.100.7',
      headers => {'user-agent' => $FIREFOX},
    },
    {status => 200}
  );
}
Iczelia::Analytics::log_request(
  $db,
  {
    path    => '/blog/foo/',
    method  => 'GET',
    remote  => '203.0.113.9',
    headers => {'user-agent' => $GOOGLEBOT},
  },
  {status => 200}
);
Iczelia::Analytics::flush($db);
is($db->one('SELECT COUNT(*) FROM analytics_events'), 4, 'four events logged');

# Derived UA columns land on the row; raw human UA does not.
my $human = $db->row(
  q{SELECT * FROM analytics_events WHERE ua_class != 'bot' LIMIT 1});
is($human->{browser}, 'Firefox', 'human browser derived');
is($human->{os},      'Linux',   'human os derived');
is($human->{device},  'desktop', 'human device derived');
is($human->{bot_ua},  undef,     'no raw UA stored for humans');

my $bot = $db->row(q{SELECT * FROM analytics_events WHERE ua_class = 'bot'});
is($bot->{device}, 'bot',   'bot device');
is($bot->{browser}, undef,  'bot has no browser family');
like($bot->{bot_ua}, qr/Googlebot/, 'raw bot UA stored');

# 2. Skipped paths don't get logged.
for my $p (qw(/healthz /admin/foo /cms.css)) {
  Iczelia::Analytics::log_request(
    $db,
    {path => $p, method => 'GET', remote => 'x', headers => {}},
    {status => 200}
  );
}
Iczelia::Analytics::flush($db);
is($db->one('SELECT COUNT(*) FROM analytics_events'),
  4, 'admin/healthz/static skipped');

# 3. Aggregator. Push events back a day so the rollup fires.
$db->do_('UPDATE analytics_events SET ts = ts - 86400');
Iczelia::Analytics::aggregate_due($db);

my %by_path =
  map {$_->{path} => $_} @{$db->all('SELECT * FROM analytics_daily')};
is(scalar(keys %by_path), 2, 'two distinct paths in daily roll-up');
is($by_path{'/blog/foo/'}{views}, 3, 'foo got 3 views');
is($by_path{'/blog/foo/'}{bots},  1, 'foo got 1 bot view');
is($by_path{'/blog/bar/'}{views}, 1, 'bar got 1 view');
is($db->one('SELECT COUNT(*) FROM analytics_events'), 0, 'old events trimmed');

# 4. UA roll-up.
my %ua;
$ua{"$_->{kind}:$_->{label}"} = $_->{count}
  for @{$db->all('SELECT * FROM analytics_ua')};
is($ua{'browser:Firefox'}, 3, 'browser roll-up');
is($ua{'os:Linux'},        3, 'os roll-up');
is($ua{'device:desktop'},  3, 'device roll-up');
is($ua{'device:bot'},      1, 'bot device roll-up');
ok((grep {/^bot:/} keys %ua), 'raw bot UA roll-up');

# 5. Dashboard data.
my $d = Iczelia::Analytics::dashboard_data($db, range => 'all');
is($d->{totals}{views}, 4, 'totals.views = 4');
is($d->{totals}{bots},  1, 'totals.bots = 1');
ok(scalar(@{$d->{top_paths}}) >= 2, 'top_paths populated');
is($d->{ua}{browsers}[0]{label}, 'Firefox', 'top browser is Firefox');
is($d->{ua}{browsers}[0]{count}, 3,         'top browser count');
ok(scalar(@{$d->{ua}{bots}}) >= 1, 'bot breakdown populated');
ok((grep {$_->{label} eq 'desktop'} @{$d->{ua}{devices}}),
  'devices breakdown has desktop');

done_testing;
