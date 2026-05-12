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

use Iczelia::Process;
use Iczelia::Media;

plan skip_all => 'ImageMagick `convert` not in PATH'
  unless Iczelia::Process::have_bin('convert');

# Generate a 600x400 test image with `convert`.
my $dir = File::Temp->newdir;
my $src = "$dir/src.png";
my $rc  = system('convert', '-size', '600x400', 'plasma:', $src);
plan skip_all => 'cannot generate test image' if $rc != 0 || !-s $src;

my $orig_size = -s $src;

# 1. Thumbnail generation: should produce a 400x300 image.
my $thumb = "$dir/src.thumb.png";
my $ok    = Iczelia::Media::make_thumb($src, $thumb);
ok($ok,       'make_thumb succeeded');
ok(-s $thumb, 'thumbnail file exists');

if (Iczelia::Process::have_bin('identify')) {
  my $size =
    Iczelia::Process::run_capped(['identify', '-format', '%wx%h', $thumb],
    timeout => 4);
  is($size, '400x300', 'thumbnail is 400x300');
}

# 2. Thumb naming convention.
is(Iczelia::Media::thumb_filename_for('abc.png'),
  'abc.thumb.png', 'thumb_filename_for adds .thumb');

# 3. Skip thumbnail if source is already small.
my $small = "$dir/small.png";
system('convert', '-size', '100x100', 'plasma:', $small);
my $small_thumb = "$dir/small.thumb.png";
my $small_ok    = Iczelia::Media::make_thumb($small, $small_thumb);
ok(!$small_ok, 'no thumb needed when source already small');

# 4. oxipng (if installed) shrinks the file.
if (Iczelia::Process::have_bin('oxipng')) {
  Iczelia::Media::optimize_png($src);
  my $new_size = -s $src;
  ok($new_size <= $orig_size,
    "oxipng didn't grow the file ($orig_size -> $new_size)");
}

done_testing;
