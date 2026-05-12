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

use_ok('Iczelia::Router');

my $r = Iczelia::Router->new;
$r->get('/',            sub {['home']});
$r->get('/about/',      sub {['about']});
$r->get('/blog/:slug/', sub {my $req = shift; ['post', $req->{caps}{slug}]});
$r->post('/admin/save', sub {['save']});
$r->get('/static/*rest',
  sub {my $req = shift; ['static', $req->{caps}{rest}]});

sub mk {
  my $m = $_[0];
  my ($h, $caps) = $r->match($m, $_[1]);
  my $req = {caps => $caps};
  return $h ? $h->($req) : undef;
}

is_deeply mk(GET  => '/'),                 ['home'],            'home';
is_deeply mk(GET  => '/about/'),           ['about'],           'about';
is_deeply mk(GET  => '/blog/foo-bar/'),    ['post', 'foo-bar'], 'slug capture';
is_deeply mk(POST => '/admin/save'),       ['save'],            'admin save';
is_deeply mk(GET  => '/static/css/x.css'), ['static', 'css/x.css'], 'wildcard';
is mk(GET => '/nonexistent'), undef, 'no match';

# Method mismatch returns "matched_path"
{
  my ($h, $c, $mp) = $r->match(POST => '/about/');
  ok(!$h, 'wrong method => no handler');
  ok($mp, 'wrong method => matched_path set');
}

done_testing;
