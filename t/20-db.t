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

use_ok('Iczelia::DB');

my $tmp = File::Temp->new(SUFFIX => '.db');
my $db  = Iczelia::DB->connect("$tmp");

$db->do_(q{CREATE TABLE k (id INTEGER PRIMARY KEY, name TEXT, v INTEGER)});
$db->do_(q{INSERT INTO k(name,v) VALUES(?,?)}, 'a', 1);
$db->do_(q{INSERT INTO k(name,v) VALUES(?,?)}, 'b', 2);

is($db->one('SELECT count(*) FROM k'), 2, 'two rows');
is_deeply(
  $db->row('SELECT * FROM k WHERE name=?', 'a'),
  {id => 1, name => 'a', v => 1},
  'row by name'
);

my $rows = $db->all('SELECT name FROM k ORDER BY id');
is_deeply([map {$_->{name}} @$rows], ['a', 'b'], 'all rows');

is_deeply($db->col('SELECT name FROM k ORDER BY id'), ['a', 'b'], 'col');

eval {
  $db->tx(
    sub {
      my $d = shift;
      $d->do_('INSERT INTO k(name,v) VALUES(?,?)', 'c', 3);
      die "boom";
    }
  );
};
ok($@, 'tx rolls back on die');
is($db->one('SELECT count(*) FROM k'), 2, 'rollback worked');

$db->tx(
  sub {my $d = shift; $d->do_('INSERT INTO k(name,v) VALUES(?,?)', 'c', 3);});
is($db->one('SELECT count(*) FROM k'), 3, 'tx commit works');

$db->do_(q{CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)});
$db->set_setting('foo', 'bar');
is($db->setting('foo'),            'bar', 'setting roundtrip');
is($db->setting('missing', 'def'), 'def', 'setting default');

done_testing;
