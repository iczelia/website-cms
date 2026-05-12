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

# The /wp-admin and /.env honeypot routes serve share/bomb.gz (gzip).

use strict;
use warnings;
use Test::More;
use FindBin ();
use lib "$FindBin::Bin/../lib";
use IO::Uncompress::Gunzip ();

use Iczelia::Router;
use Iczelia::Handlers::Honeypot;
use Iczelia::Handlers::Feeds;

is_deeply([@Iczelia::Handlers::Honeypot::PATHS], ['/wp-admin', '/.env'],
  'honeypot paths');

my $router = Iczelia::Router->new;
my $ctx    = {cfg => {'share-dir' => "$FindBin::Bin/../share"}};
Iczelia::Handlers::Honeypot->register($router, $ctx);

my $first_body;
for my $path (@Iczelia::Handlers::Honeypot::PATHS) {
  my ($h, $caps) = $router->match('GET', $path);
  ok($h, "route registered: $path") or next;
  my $resp = $h->({caps => $caps});
  is($resp->{status}, 200, "$path: 200");
  is($resp->{headers}{'Content-Encoding'},
    'gzip', "$path: Content-Encoding gzip");
  ok($resp->{_no_cache}, "$path: _no_cache (out of the daemon cache)");
  is(substr($resp->{body}, 0, 3),
    "\x1f\x8b\x08", "$path: body is a gzip stream");
  cmp_ok(length $resp->{body}, '>', 1_000_000,  "$path: body is substantial");
  cmp_ok(length $resp->{body}, '<', 50_000_000, "$path: body is compressed");
  $first_body //= $resp->{body};
}

# Inflate enough to confirm it decodes to NUL bytes without
# materialising all ~10 GiB.
SKIP: {
  skip 'no bomb body', 2 unless defined $first_body;
  open my $in, '<', \$first_body or die "open scalar: $!";
  my $gz = IO::Uncompress::Gunzip->new($in, MultiStream => 1)
    or die "gunzip: $IO::Uncompress::Gunzip::GunzipError";
  my ($total, $buf, $nonzero) = (0, '', 0);
  while ((my $n = $gz->read($buf, 1 << 20)) > 0) {
    $total += $n;
    $nonzero++ if $buf =~ /[^\0]/;
    last if $total >= (130 << 20);
  }
  cmp_ok($total, '>=', 64 << 20, 'inflates to at least one full member');
  is($nonzero, 0, 'decoded bytes are all NUL');
}

{
  my $robots = Iczelia::Handlers::Feeds::_robots(
    {db => bless({}, 't::FakeDB')});
  is($robots->{headers}{'Content-Type'},
    'text/plain; charset=utf-8', 'robots.txt content type');
  like($robots->{body}, qr{^Disallow: /admin/$}m,    'robots disallows /admin/');
  like($robots->{body}, qr{^Disallow: /wp-admin$}m,  'robots disallows /wp-admin');
  like($robots->{body}, qr{^Disallow: /\.env$}m,     'robots disallows /.env');
  like($robots->{body}, qr{^Sitemap: \S+/sitemap\.xml$}m, 'robots has Sitemap');
}

done_testing;

package t::FakeDB;
sub one { return undef }
