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

use Iczelia::Schema;

my $s = Iczelia::Schema->new(dir => "$FindBin::Bin/../share/templates/pages");

my $tmp = File::Temp->newdir;
open my $tfh, '>', "$tmp/inttest.json" or die "open: $!";
print $tfh <<'JSON';
{ "title": "Int test", "fields": [
  { "name": "n", "kind": "int", "min": 1, "max": 3, "default": 1 }
] }
JSON
close $tfh;
my $intsch = Iczelia::Schema->new(dir => "$tmp");

# 1: load
my $sch = $s->load('about');
is($sch->{title}, 'About', 'about title');
cmp_ok(scalar @{$sch->{fields}},
  '>=', 6, 'about has at least the original 6 fields');

# 2: parse text + markdown fields
my ($d, $errs) = $s->parse_form(
  'about',
  {
    intro     => 'hello',
    what_i_do => 'stuff',
    currently => 'now',
    colophon  => 'fin',
  }
);
is($d->{intro}, 'hello', 'intro parsed');

# 3: parse kv-table
($d, $errs) = $s->parse_form(
  'about',
  {
    'vitals__row0__key'   => 'name',
    'vitals__row0__value' => 'kamila',
    'vitals__row2__key'   => 'tea',
    'vitals__row2__value' => 'strong',
  }
);
is_deeply(
  $d->{vitals},
  [{key => 'name', value => 'kamila'}, {key => 'tea', value => 'strong'},],
  'kv-table parsed in order, gaps OK'
);

# 4: skip wholly empty rows
($d, $errs) = $s->parse_form(
  'about',
  {
    'vitals__row0__key'   => 'name',
    'vitals__row0__value' => 'kamila',
    'vitals__row1__key'   => '',
    'vitals__row1__value' => '',
  }
);
is(scalar @{$d->{vitals}}, 1, 'empty rows pruned');

# 5: int coerced
($d, $errs) = $intsch->parse_form('inttest', {n => '2'});
is($d->{n}, 2, 'int parsed');

# 6: int min/max enforced
($d, $errs) = $intsch->parse_form('inttest', {n => '99'});
is($d->{n}, 3, 'int clamped to max');

# 7: encode + decode roundtrip
my $json = $s->encode({a => 1, b => [{c => 'd'}]});
is_deeply($s->decode($json), {a => 1, b => [{c => 'd'}]}, 'roundtrip');

done_testing;
