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

my @mods = qw(
  Iczelia
  Iczelia::Config
  Iczelia::DB
  Iczelia::HTTP
  Iczelia::Router
  Iczelia::Server
  Iczelia::SelfUpdate
  Iczelia::UA
  Iczelia::Analytics
  Iczelia::Subpages
);

plan tests => scalar @mods;

for my $m (@mods) {
  use_ok($m) or BAIL_OUT("cannot load $m");
}
