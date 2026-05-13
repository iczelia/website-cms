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
use FindBin ();
use lib "$FindBin::Bin/../lib";

use Iczelia::Compress;
use Compress::Zlib    ();

my $payload =
    "<!doctype html><html><head><title>iczelia :: test</title></head><body>"
  . ("<p>lorem ipsum dolor sit amet, consectetur adipiscing elit.</p>" x 200)
  . "</body></html>";

# === gzip (zopfli, slow + tight) ===
my $z = Iczelia::Compress::gzip($payload);
ok(defined $z && length $z, 'gzip() returned a payload');
ok(length $z < length $payload, 'gzip() shrinks the body');
is(substr($z, 0, 2), pack('C*', 0x1f, 0x8b), 'gzip magic prefix');
is(Compress::Zlib::memGunzip($z), $payload, 'gzip() round-trips');

# Iterations knob is honoured: more iterations should not be larger.
my $z1  = Iczelia::Compress::gzip($payload, iterations => 1);
my $z15 = Iczelia::Compress::gzip($payload, iterations => 15);
ok(length $z15 <= length $z1, 'higher iteration count is not worse');
is(Compress::Zlib::memGunzip($z1),  $payload, 'low-iter gzip round-trips');
is(Compress::Zlib::memGunzip($z15), $payload, 'high-iter gzip round-trips');

# === gzip_fast (Compress::Zlib level 9) ===
my $zf = Iczelia::Compress::gzip_fast($payload);
ok(defined $zf && length $zf, 'gzip_fast() returned a payload');
is(substr($zf, 0, 2), pack('C*', 0x1f, 0x8b), 'gzip_fast magic prefix');
is(Compress::Zlib::memGunzip($zf), $payload, 'gzip_fast() round-trips');

# Zopfli should not produce strictly larger output than zlib level 9 on
# realistic HTML (the whole reason we pay the iteration cost).
ok(length $z <= length $zf, 'zopfli gzip is no larger than zlib level-9 gzip');

# Empty + undef handling.
is(Iczelia::Compress::gzip(undef),      undef, 'gzip(undef) is undef');
is(Iczelia::Compress::gzip(''),         undef, 'gzip("") is undef');
is(Iczelia::Compress::gzip_fast(undef), undef, 'gzip_fast(undef) is undef');
is(Iczelia::Compress::gzip_fast(''),    undef, 'gzip_fast("") is undef');

# === brotli ===
my $b = Iczelia::Compress::brotli($payload, 5);
ok(defined $b && length $b, 'brotli() returned a payload');
ok(length $b < length $payload, 'brotli() shrinks the body');
is(IO::Compress::Brotli::unbro($b), $payload, 'brotli() round-trips');

done_testing;
