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

# subpage_files_listing carries the listing metadata columns so a
# directory render never touches the table, where every row sits next to
# its content blob. Listing the root of a large bundle otherwise faults
# in the whole table. The plan assertions are the real guard: adding a
# column to the directory_entries SELECT without adding it to the index
# silently drops COVERING and brings the stall back.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Migrate;
use Iczelia::Subpages;

my $tmp = File::Temp->newdir;

# A DB at the pre-migration shape: schema.sql minus the new index.
my $db = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->dbh->do('DROP INDEX IF EXISTS subpage_files_listing');

sub has_index {
  $db->one(q{SELECT 1 FROM sqlite_master
               WHERE type='index' AND name=? LIMIT 1}, $_[0]) ? 1 : 0;
}

ok(!has_index('subpage_files_listing'), 'index absent before migrate');

is(Iczelia::Migrate::run($db), 1, 'one migration applied');
ok(has_index('subpage_files_listing'), 'index created');

is(Iczelia::Migrate::run($db), 0, 'rerun is a no-op');
is(Iczelia::Migrate::run($db), 0, 'and stays a no-op');

sub plan_for {
  my ($sql, @bind) = @_;
  return join ' ', map { $_->{detail} }
    @{ $db->all("EXPLAIN QUERY PLAN $sql", @bind) };
}

my $id = Iczelia::Subpages::create($db, 'doc', 'Doc', [
  {
    path         => 'a/b.html',
    content      => '<p>x</p>',
    content_type => 'text/html; charset=utf-8',
    size         => 8,
    is_binary    => 0,
  },
]);

# directory_entries, root branch: the whole-bundle scan.
like(
  plan_for(q{SELECT path, size, updated_at, content_type, is_binary
               FROM subpage_files WHERE subpage_id=? ORDER BY path}, $id),
  qr/COVERING INDEX subpage_files_listing/,
  'root listing scan is covering'
);

# directory_entries, subtree branch.
like(
  plan_for(q{SELECT path, size, updated_at, content_type, is_binary
               FROM subpage_files
              WHERE subpage_id=? AND path >= ? AND path < ?
              ORDER BY path}, $id, 'a/', 'a0'),
  qr/COVERING INDEX subpage_files_listing/,
  'subtree listing scan is covering'
);

# Subpages::files (admin bundle view). `id` is the rowid, which every
# index carries implicitly, so this stays covering without listing it.
like(
  plan_for(q{SELECT id, path, content_type, size, is_binary, updated_at
               FROM subpage_files WHERE subpage_id=? ORDER BY path}, $id),
  qr/COVERING INDEX subpage_files_listing/,
  'admin file list is covering'
);

# Serving one file still goes straight to the row: it needs the blob, so
# a covering scan here would be the wrong plan.
unlike(
  plan_for(q{SELECT * FROM subpage_files WHERE subpage_id=? AND path=?},
    $id, 'a/b.html'),
  qr/COVERING/,
  'single-file fetch still seeks the row'
);

# The fresh-install path must not need the migration at all.
my $fresh = Iczelia::DB->connect("$tmp/fresh.db");
$fresh->apply_schema_file("$FindBin::Bin/../share/schema.sql");
ok(
  $fresh->one(q{SELECT 1 FROM sqlite_master
                  WHERE type='index' AND name='subpage_files_listing'}),
  'schema.sql creates the index on a fresh install'
);

done_testing;
