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

# Pages that embed a per-visitor anti-CSRF token bound to the
# iczelia_csrf cookie (the public guestbook form, the admin login
# form) must be served uncacheable -- otherwise the nginx edge cache
# or a browser cache hands one visitor's token to another, which
# surfaces as a "spurious 400 csrf" on submit.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Template;
use Iczelia::Render;
use Iczelia::Auth;
use Iczelia::Handlers::Guestbook;
use Iczelia::Handlers::Admin;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->apply_schema_file("$FindBin::Bin/../share/seed.sql");

my $tpl  = Iczelia::Template->new(dirs => ["$FindBin::Bin/../share/templates"]);
my $rnd  = Iczelia::Render->new(db => $db, template => $tpl);
my $auth = Iczelia::Auth->new(db => $db, cookie_secret => 'a' x 64);

require Iczelia::Context;
my $ctx = Iczelia::Context->new(db => $db, template => $tpl, render => $rnd, auth => $auth);

sub req {
  my ($path) = @_;
  return {
    method  => 'GET',
    path    => $path,
    cookies => {},
    qparams => {},
    params  => {},
    headers => {},
  };
}

sub cc { lc(($_[0]->{headers}{'Cache-Control'} // '')) }

{
  my $resp = Iczelia::Handlers::Guestbook::render_public($ctx, req('/guestbook/'));
  like(cc($resp), qr/\bno-store\b/, 'guestbook GET: Cache-Control no-store');
  ok($resp->{_no_cache}, 'guestbook GET: _no_cache set (out of the daemon cache)');
  ok(ref $resp->{cookies} eq 'ARRAY' && @{$resp->{cookies}},
    'first visit mints the iczelia_csrf cookie');
  like($resp->{cookies}[0], qr/^iczelia_csrf=[0-9a-f]+\.[0-9a-f]+/,
    'cookie is the signed anon-CSRF token');

  # A returning visitor (cookie already valid) gets no new Set-Cookie --
  # which is exactly when the response used to be edge-cacheable. It
  # must still be no-store.
  my $cookie_val = ($resp->{cookies}[0] =~ /^iczelia_csrf=([^;]+)/)[0];
  my $r2 = req('/guestbook/');
  $r2->{cookies}{iczelia_csrf} = $cookie_val;
  my $resp2 = Iczelia::Handlers::Guestbook::render_public($ctx, $r2);
  like(cc($resp2), qr/\bno-store\b/, 'returning visitor: still no-store');
  ok(!($resp2->{cookies} && @{$resp2->{cookies}}), 'returning visitor: no Set-Cookie');
}

{
  my $resp = Iczelia::Handlers::Admin::_login_form($ctx, req('/admin/login'));
  like(cc($resp), qr/\bno-store\b/, 'login GET: Cache-Control no-store');
  ok($resp->{_no_cache}, 'login GET: _no_cache set');
}

done_testing;
