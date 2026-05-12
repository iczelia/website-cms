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
use Iczelia::Tex;

my $tmpdir = File::Temp->newdir;
my $tmpd2  = File::Temp->newdir;                        # work dir for Tex
my $db     = Iczelia::DB->connect("$tmpdir/test.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $tex = Iczelia::Tex->new(
  db      => $db,
  tmp_dir => "$tmpd2",
  gc_age  => 3600,       # 1 hour
);

# Seed two cache rows: one fresh, one ancient.
$db->do_(
  q{INSERT INTO tex_cache(hash, display, html, created_at)
           VALUES('fresh', 0, '<x/>', strftime('%s','now'))}
);
$db->do_(
  q{INSERT INTO tex_cache(hash, display, html, created_at)
           VALUES('ancient', 0, '<x/>', strftime('%s','now') - 7200)}
);

is($db->one('SELECT COUNT(*) FROM tex_cache'), 2, 'two rows seeded');

$tex->gc;
is($db->one('SELECT COUNT(*) FROM tex_cache'), 1,
  'gc dropped the ancient row');
my $left = $db->one('SELECT hash FROM tex_cache');
is($left, 'fresh', 'fresh row survived');

done_testing;
