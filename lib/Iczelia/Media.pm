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

package Iczelia::Media;
use strict;
use warnings;
use Iczelia::Process ();

# Image post-processing helpers. Run external tools (oxipng, ImageMagick
# convert/identify) under a wall-clock timeout so a malicious upload
# can't stall the worker. All operations are best-effort: failure leaves
# the original file in place.

# Run oxipng against $path (in-place). PNGs only. Skips silently if
# oxipng isn't installed. Returns 1 on success, 0 otherwise.
sub optimize_png {
  my ($path) = @_;
  return 0 unless defined $path && -f $path;
  return 0 unless Iczelia::Process::have_bin('oxipng');
  my $out = Iczelia::Process::run_capped(
    ['oxipng', '-o', '4', '--strip', 'safe', '--quiet', $path],
    timeout => 5);
  return defined $out ? 1 : 0;
}

# Generate a 400x300 thumbnail at $thumb. Skips when source is already
# small enough. Returns 1 on success, 0 otherwise. Requires
# `convert` and `identify` from ImageMagick.
sub make_thumb {
  my ($src, $thumb, %opt) = @_;
  return 0 unless defined $src && -f $src && defined $thumb;
  return 0 unless Iczelia::Process::have_bin('convert');
  my $W = $opt{width}  || 400;
  my $H = $opt{height} || 300;
  if (Iczelia::Process::have_bin('identify')) {
    my $size =
      Iczelia::Process::run_capped(['identify', '-format', '%wx%h', $src],
      timeout => 4);
    if (defined $size && $size =~ /^(\d+)x(\d+)$/) {
      my ($w, $h) = ($1, $2);

      # Source already smaller than the thumbnail target - skip.
      return 0 if $w <= $W && $h <= $H;
    }
  }
  my $out = Iczelia::Process::run_capped(
    [
      'convert',    $src,       '-auto-orient', '-resize',
      "${W}x${H}^", '-gravity', 'center',       '-extent',
      "${W}x${H}",  '-strip',   $thumb
    ],
    timeout => 8
  );
  return (defined $out && -f $thumb && -s $thumb) ? 1 : 0;
}

# Derive the per-image thumbnail filename. Always <basename>.thumb.<ext>.
sub thumb_filename_for {
  my ($filename) = @_;
  return undef unless defined $filename && length $filename;
  if ($filename =~ /^(.+)\.([^.]+)$/) {
    return "$1.thumb.$2";
  }
  return undef;
}

1;
