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

# Tiny stub renderer that swallows invalidate_* calls. Content.pm calls
# the renderer on every mutating op; we don't need real rendering here.
package R;
sub new             {bless {}, shift}
sub invalidate_post { }
sub invalidate_page { }
sub invalidate_home { }
sub invalidate_all  { }

package main;

# Direct unit tests on _word_count.
is(Iczelia::Content::_word_count(''),      0, 'empty body -> 0');
is(Iczelia::Content::_word_count('a b c'), 3, 'three plain words');
is(Iczelia::Content::_word_count("one\ntwo  three\tfour"),
  4, 'whitespace varieties split');
is(Iczelia::Content::_word_count("hello ```code\nignored words```"),
  1, 'fenced code stripped');
is(Iczelia::Content::_word_count('see `inline code` here'),
  2, 'inline code stripped (only see+here remain)');
is(Iczelia::Content::_word_count('go [click here](https://example.com) now'),
  4, 'link visible text retained, URL excluded');
is(Iczelia::Content::_word_count('![alt text here](/img.png) caption'),
  4, 'image alt counted, URL excluded');
is(Iczelia::Content::_word_count('paragraph <em>with html</em> tags'),
  4, 'html tags stripped');

# Round-trip via Content::create_post and Content::update_post.
my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/test.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $c = Iczelia::Content->new(db => $db, render => R->new);

my $slug = $c->create_post(
  'blog',
  {
    title => 'hello',
    date  => '2026-05-09',
    body  => "the quick brown fox\njumps over the lazy dog",
  }
);
my $row = $db->row('SELECT word_count FROM posts WHERE kind=? AND slug=?',
  'blog', $slug);
is($row->{word_count}, 9, 'create_post stores word_count');

$c->update_post(
  'blog', $slug,
  {
    title => 'hello',
    date  => '2026-05-09',
    body  => "shorter body now",
  }
);
$row = $db->row('SELECT word_count FROM posts WHERE kind=? AND slug=?',
  'blog', $slug);
is($row->{word_count}, 3, 'update_post recomputes word_count');

done_testing;
