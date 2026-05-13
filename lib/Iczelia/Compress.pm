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

use IO::Compress::Brotli ();
use Gzip::Zopfli         qw(zopfli_compress);
use Compress::Zlib       ();

# In-process gzip (Gzip::Zopfli) and brotli (IO::Compress::Brotli).

# Content-Type predicate: returns 1 if compressing this body would
# meaningfully shrink it (text/* and structured-data application/*).
# Already-compressed media (image/*, audio/*, video/*, font/*,
# application/zip|gzip|...) returns 0.
my $COMPRESSIBLE_RE =
  qr{^(?:text/|application/(?:json|javascript|xml|[\w.+-]+\+xml)\b)}i;
my $BINARY_MEDIA_RE = qr{^(?:image|audio|video|font)/}i;
my $BINARY_APP_RE   =
  qr{^application/(?:zip|gzip|x-tar|x-bzip|octet-stream|font-woff|x-protobuf|pdf)\b}i;

sub is_compressible_ct {
  my ($ct) = @_;
  return 0 unless defined $ct;
  return ($ct =~ $COMPRESSIBLE_RE) ? 1 : 0;
}

sub is_binary_media_ct {
  my ($ct) = @_;
  return 0 unless defined $ct;
  return 1 if $ct =~ $BINARY_MEDIA_RE;
  return 1 if $ct =~ $BINARY_APP_RE;
  return 0;
}

sub brotli {
  my ($body, $quality) = @_;
  return undef unless defined $body && length $body;
  my $out = eval {
    defined $quality
      ? IO::Compress::Brotli::bro($body, $quality)
      : IO::Compress::Brotli::bro($body);
  };
  return (defined $out && length $out) ? $out : undef;
}

# Batch-quality zopfli gzip. Pay the cost once per cached row in the
# warmer; serve from the response cache after that. For per-request
# compression on cache misses use gzip_fast.
sub gzip {
  my ($body, %opt) = @_;
  return undef unless defined $body && length $body;
  my $iter = $opt{iterations} || 15;
  my $out  = eval {zopfli_compress($body, numiterations => $iter)};
  return (defined $out && length $out) ? $out : undef;
}

sub gzip_fast {
  my ($body) = @_;
  return undef unless defined $body && length $body;
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
