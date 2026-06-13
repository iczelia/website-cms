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

use Iczelia::Router;
use Iczelia::Handlers::Feeds;

my $r = Iczelia::Router->new;
Iczelia::Handlers::Feeds->register($r, undef);

# Common feed-discovery URLs permanently redirect to the canonical feeds.
my %expect = (
  '/rss'       => '/index.xml',
  '/rss/'      => '/index.xml',
  '/feed'      => '/index.xml',
  '/feed/'     => '/index.xml',
  '/feeds'     => '/index.xml',
  '/rss.rdf'   => '/index.xml',
  '/feed.rss'  => '/index.xml',
  '/index.rss' => '/index.xml',
  '/atom'      => '/feed.xml',
  '/atom/'     => '/feed.xml',
  '/atom.xml'  => '/feed.xml',
  '/feed.atom' => '/feed.xml',
);

for my $from (sort keys %expect) {
  my ($h, $caps) = $r->match('GET', $from);
  ok($h, "alias $from is routed");
  my $resp = $h->({caps => $caps});
  is($resp->{status}, 301, "$from -> permanent redirect");
  is($resp->{headers}{Location}, $expect{$from},
    "$from -> $expect{$from}");
}

# The real feeds keep serving content, not redirects.
for my $real ('/feed.xml', '/index.xml', '/rss.xml') {
  my ($h) = $r->match('GET', $real);
  ok($h, "real feed $real is routed");
}

done_testing();
