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
use Iczelia::Content;

package R;
sub new             {bless {}, shift}
sub invalidate_post { }
sub invalidate_page { }
sub invalidate_home { }
sub invalidate_all  { }

package main;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/test.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

# Verify FTS5 is available; skip otherwise.
my $ok = eval {
  $db->one(q{SELECT 1 FROM posts_fts LIMIT 1});
  1;
};
plan skip_all => 'SQLite FTS5 not available' unless $ok;

my $c = Iczelia::Content->new(db => $db, render => R->new);

$c->create_post(
  'blog',
  {
    title => 'fox jump',
    body  => 'the quick brown fox jumps over the lazy dog',
    date  => '2026-05-09',
    tags  => 'animals,classic',
  }
);
$c->create_post(
  'blog',
  {
    title => 'cat nap',
    body  => 'a cat naps on a windowsill in afternoon sun',
    date  => '2026-05-09',
    tags  => 'animals',
  }
);
$c->create_post(
  'journal',
  {
    title => 'unrelated',
    body  => 'numbers and bytes today',
    date  => '2026-05-09',
  }
);

my $rows = $db->all(
  q{SELECT slug, kind, title, snippet(posts_fts, 3, '<mark>', '</mark>', '...', 24) AS sn
        FROM posts_fts
       WHERE posts_fts MATCH ?
         AND kind IN ('blog','journal')
    ORDER BY bm25(posts_fts) LIMIT 30},
  '"quick"'
);
ok(scalar(@$rows) >= 1, 'search for quick finds at least one result');
like($rows->[0]{sn}, qr/<mark>quick<\/mark>/, 'snippet highlights match');
is($rows->[0]{slug}, 'fox-jump', 'fox post wins for "quick"');

# Rename the post; trigger should re-index, search by new slug must work.
$c->update_post(
  'blog',
  'fox-jump',
  {
    title => 'fox jump v2',
    body  => 'the quick brown fox jumps over the lazy dog',
    date  => '2026-05-09',
    slug  => 'fox-jump-v2',
  }
);
$rows = $db->all(q{SELECT slug FROM posts_fts WHERE posts_fts MATCH ? LIMIT 5},
  '"quick"');
my @slugs = map {$_->{slug}} @$rows;
ok(grep({$_ eq 'fox-jump-v2'} @slugs), 'renamed slug indexed');
ok(!grep({$_ eq 'fox-jump'} @slugs),   'old slug deindexed');

# Delete a post; it disappears from the index.
$c->delete_post('blog', 'cat-nap');
$rows = $db->all(q{SELECT slug FROM posts_fts WHERE posts_fts MATCH ? LIMIT 5},
  '"cat"');
is(scalar(@$rows), 0, 'deleted post removed from FTS index');

# Rebuild.
$db->do_(q{INSERT INTO posts_fts(posts_fts) VALUES('rebuild')});
$rows = $db->all(
  q{SELECT slug FROM posts_fts WHERE posts_fts MATCH '"fox"' LIMIT 5});
ok(scalar(@$rows) >= 1, 'rebuild keeps surviving rows');

done_testing;
