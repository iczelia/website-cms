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
my $c = Iczelia::Content->new(db => $db, render => R->new);

# Create a post with slug "foo".
my $foo = $c->create_post(
  'blog',
  {
    title => 'hello',
    body  => '...',
    date  => '2026-05-09',
    slug  => 'foo',
  }
);
is($foo, 'foo', 'created with slug foo');

# Rename to "bar". Expect an alias "foo" -> post.id.
$c->update_post(
  'blog', 'foo',
  {
    title => 'hello',
    body  => '...',
    date  => '2026-05-09',
    slug  => 'bar',
  }
);
my $row = $db->row('SELECT * FROM posts WHERE id=1');
is($row->{slug}, 'bar', 'post slug updated to bar');
my $alias = $db->row('SELECT * FROM post_aliases WHERE kind=? AND from_slug=?',
  'blog', 'foo');
ok($alias, 'alias foo recorded');
is($alias->{post_id}, $row->{id}, 'alias points at post');

# Rename again to "baz". Expect both aliases foo and bar to point at the
# (still-the-same) post.
$c->update_post(
  'blog', 'bar',
  {
    title => 'hello',
    body  => '...',
    date  => '2026-05-09',
    slug  => 'baz',
  }
);
my $aliases = $db->col(
  'SELECT from_slug FROM post_aliases WHERE post_id=? ORDER BY from_slug',
  $row->{id});
is_deeply($aliases, ['bar', 'foo'], 'both old slugs aliased');

# Delete the post: aliases cascade away.
$c->delete_post('blog', 'baz');
my $n =
  $db->one('SELECT COUNT(*) FROM post_aliases WHERE post_id=?', $row->{id});
is($n, 0, 'aliases cleaned up on post delete');

done_testing;
