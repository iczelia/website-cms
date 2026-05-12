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

my $slug = $c->create_post(
  'blog',
  {
    title => 'v1',
    body  => 'one',
    date  => '2026-05-09',
  }
);
my $post = $db->row('SELECT * FROM posts WHERE slug=?', $slug);

# 1: Three updates -> three revisions numbered 1,2,3 (each captures the
# state BEFORE the update).
for my $body (qw(two three four)) {
  $c->update_post(
    'blog', $slug,
    {
      title  => "v$body",
      body   => $body,
      date   => '2026-05-09',
      author => 'kamila',
    }
  );
}
my $revs = $db->all(
  'SELECT revision_num, title, body, author FROM post_revisions
      WHERE post_id=? ORDER BY revision_num', $post->{id}
);
is(scalar(@$revs), 3, 'three revisions captured');
is_deeply([map {$_->{revision_num}} @$revs], [1, 2, 3], 'numbered 1, 2, 3');
is($revs->[0]{title},  'v1',     'rev 1 captures original v1 state');
is($revs->[0]{body},   'one',    'rev 1 body is "one"');
is($revs->[2]{title},  'vthree', 'rev 3 captures the v=three state');
is($revs->[2]{author}, 'kamila', 'author propagated');

# 2: Restore rev 1 -> body matches and a 4th revision is recorded
my $rev1 =
  $db->row('SELECT * FROM post_revisions WHERE post_id=? AND revision_num=1',
  $post->{id});
$c->update_post(
  'blog', $slug,
  {
    title  => $rev1->{title},
    body   => $rev1->{body},
    date   => $rev1->{date},
    author => 'kamila',
  }
);
my $cur = $db->row('SELECT * FROM posts WHERE slug=?', $slug);
is($cur->{body}, 'one', 'restore brought body back to "one"');
my $n_revs =
  $db->one('SELECT COUNT(*) FROM post_revisions WHERE post_id=?', $post->{id});
is($n_revs, 4, 'restore is itself recorded as rev 4');

# 3: 60 more updates -> exactly 50 revisions remain (oldest pruned).
for my $i (1 .. 60) {
  $c->update_post(
    'blog', $slug,
    {
      title  => "x$i",
      body   => "body $i",
      date   => '2026-05-09',
      author => 'kamila',
    }
  );
}
$n_revs =
  $db->one('SELECT COUNT(*) FROM post_revisions WHERE post_id=?', $post->{id});
is($n_revs, 50, 'cap holds at 50 revisions');
my $min =
  $db->one('SELECT MIN(revision_num) FROM post_revisions WHERE post_id=?',
  $post->{id});
ok($min > 1, 'oldest revisions pruned (min > 1)');

# 4: delete_post cascades the revision rows.
$c->delete_post('blog', $slug);
my $n_left =
  $db->one('SELECT COUNT(*) FROM post_revisions WHERE post_id=?', $post->{id});
is($n_left, 0, 'revisions cascade-deleted with post');

done_testing;
