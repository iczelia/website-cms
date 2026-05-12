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

unless (`which latex 2>/dev/null` =~ /\S/
  && `which dvisvgm 2>/dev/null` =~ /\S/)
{
  plan skip_all => 'latex/dvisvgm not in PATH';
}

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $scratch = "$tmpdir/scratch";
mkdir $scratch or die "mkdir $scratch: $!";

my $tex = Iczelia::Tex->new(db => $db, tmp_dir => $scratch);

# 1: inline fragment renders to <img> with SVG data URL + px baseline shift
{
  my $h = $tex->render(0, 'x^2 + y^2');
  like $h, qr{<img\b},                           'inline returns <img>';
  like $h, qr{src="data:image/svg\+xml;base64,}, 'SVG data URL';
  like $h, qr{vertical-align:-?\d+px},   'baseline shift uses px (not em)';
  like $h, qr{class="math math-inline"}, 'has math-inline class';
  unlike $h, qr{style="[^"]*(?:height|width):},
    'no CSS height/width in style attr';
}

# 2: cache hit doesn't insert a new row
{
  $tex->render(0, 'a+b');
  my $rows = $db->one('SELECT COUNT(*) FROM tex_cache');
  $tex->render(0, 'a+b');
  my $rows2 = $db->one('SELECT COUNT(*) FROM tex_cache');
  is $rows, $rows2, 'cache prevents new insert';
}

# 3: display math has no inline style at all - centering is via CSS class
{
  my $h = $tex->render(1, 'a+b=c');
  like $h,   qr{<img\b},                    'display returns <img>';
  like $h,   qr{class="math math-display"}, 'has math-display class';
  unlike $h, qr{style=},                    'display has NO inline style';
}

# 4: malformed input -> error span (not a crash)
{
  my $h = $tex->render(0, '\thisIsNotAMacro{x}');
  like $h,   qr{tex-error}, 'bad latex returns error span';
  unlike $h, qr{<img\b},    'no <img> on error';
}

# 5: oversized input rejected
{
  my $big = 'x' x 20_000;
  my $h   = $tex->render(0, $big);
  like $h, qr{tex-error}, 'oversize rejected';
}

# 6: subscript yields nonzero depth
{
  my $h = $tex->render(0, 'x_y');
  if ($h =~ /vertical-align:-(\d+)px/) {
    cmp_ok $1, '>', 0, 'subscript has measurable depth (px)';
  }
  else {
    fail 'no vertical-align in subscript output';
  }
}

# 7: output carries alt + title with the source LaTeX
{
  my $h = $tex->render(0, 'x_y');
  like $h, qr{alt="x_y"},   'alt text = source';
  like $h, qr{title="x_y"}, 'title = source (hover tooltip)';
}

done_testing;
