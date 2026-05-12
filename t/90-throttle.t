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
use Iczelia::Throttle;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $t = Iczelia::Throttle->new(
  db     => $db,
  table  => 'login_throttle',
  max    => 3,
  window => 60,
);

# First three allowed; fourth denied
ok($t->allow('1.2.3.4'),  'first allowed');
ok($t->allow('1.2.3.4'),  'second allowed');
ok($t->allow('1.2.3.4'),  'third allowed');
ok(!$t->allow('1.2.3.4'), 'fourth denied');

# Different IP not affected
ok($t->allow('5.6.7.8'), 'different ip allowed');

# reset_ip clears
$t->reset_ip('1.2.3.4');
ok($t->allow('1.2.3.4'), 'after reset, allowed');

# guestbook_throttle uses the same schema; throttle works against either.
my $gb = Iczelia::Throttle->new(
  db     => $db,
  table  => 'guestbook_throttle',
  max    => 1,
  window => 5 * 60,
);
ok($gb->allow('9.9.9.9'),  'gb first ok');
ok(!$gb->allow('9.9.9.9'), 'gb second blocked');

done_testing;
