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

package Iczelia::Compress;
use strict;
use warnings;

# In-process gzip + brotli; oxipng stays a CLI in Cache.pm.

my $HAVE_BROTLI;
sub have_brotli {
  $HAVE_BROTLI //= (eval {require IO::Compress::Brotli; 1} ? 1 : 0);
  return $HAVE_BROTLI;
}

sub brotli {
  my ($body, $quality) = @_;
  return undef unless defined $body && length $body;
  return undef unless have_brotli();
  my $out = eval {
    defined $quality
      ? IO::Compress::Brotli::bro($body, $quality)
      : IO::Compress::Brotli::bro($body);
  };
  return (defined $out && length $out) ? $out : undef;
}

sub gzip {
  my ($body) = @_;
  return undef unless defined $body;
  require Compress::Zlib;
  my $d = Compress::Zlib::deflateInit(
    -Level      => Compress::Zlib::Z_BEST_COMPRESSION(),
    -WindowBits => -Compress::Zlib::MAX_WBITS(),
  ) or return undef;
  my ($a, $sa) = $d->deflate($body);
  return undef if $sa != Compress::Zlib::Z_OK();
  my ($b, $sb) = $d->flush;
  return undef if $sb != Compress::Zlib::Z_OK();
  my $crc   = Compress::Zlib::crc32($body);
  my $isize = length($body) % 2**32;
  return pack('CCCCVCC', 0x1f, 0x8b, 8, 0, 0, 2, 255)
       . $a . $b
       . pack('VV', $crc, $isize);
}

1;
