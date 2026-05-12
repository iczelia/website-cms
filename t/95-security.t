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

use Iczelia::HTTP;
use Iczelia::Markup;
use Iczelia::SafeMarkup;
use Iczelia::DB;
use Iczelia::Tex;

# 1. CR/LF stripped from redirect URLs (defense in depth)
{
  my $r = Iczelia::HTTP::redirect("/admin/\r\nSet-Cookie: pwn=1");
  is(
    $r->{headers}{Location},
    '/admin/Set-Cookie: pwn=1',
    'redirect strips CR/LF from URL'
  );
  unlike($r->{body}, qr/\r/,             'no CR in redirect body');
  unlike($r->{body}, qr/\n.*Set-Cookie/, 'no fake header in body');
}

# 2. CR/LF stripped from cookie pieces
{
  my $c = Iczelia::HTTP::make_cookie(
    name     => 'foo',
    value    => "bar\r\nSet-Cookie: evil=1",
    path     => "/admin\nX: y",
    samesite => 'Lax',
  );
  unlike($c, qr/\r/, 'no CR in cookie');
  unlike($c, qr/\n/, 'no LF in cookie');
}

# 3. Markdown blockquote nesting capped (no stack blow-up)
{
  my $deep = ('>' x 200) . ' x';
  my ($html) = Iczelia::Markup::render($deep);
  ok(
    length $html < length($deep) * 50,
    'deep blockquote does not explode output'
  );
}

# 4. SafeMarkup blockquote also capped
{
  my $deep = ('>' x 200) . ' x';
  my $html = Iczelia::SafeMarkup::render($deep);
  ok(length $html < length($deep) * 50, 'SafeMarkup deep blockquote bounded');
}

# 5. Markdown emphasis can't corrupt link href
{
  my ($html) = Iczelia::Markup::render('[hi](https://example.com/**zoom**)');
  like(
    $html,
    qr{href="https://example\.com/\*\*zoom\*\*"},
    'link href preserves double-asterisks (not turned into <strong>)'
  );
}

# 6. Throttle is atomic across "concurrent" calls
{
  my $tmpdir = File::Temp->newdir;
  my $db     = Iczelia::DB->connect("$tmpdir/t.db");
  $db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
  require Iczelia::Throttle;
  my $t = Iczelia::Throttle->new(
    db     => $db,
    table  => 'login_throttle',
    max    => 3,
    window => 60,
  );
  my $allowed = 0;
  for (1 .. 10) {$allowed++ if $t->allow('192.0.2.1')}
  is($allowed, 3, 'exactly 3 of 10 calls allowed');
}

# 7. DB auto-reconnects across fork
{
  my $tmpdir = File::Temp->newdir;
  my $db     = Iczelia::DB->connect("$tmpdir/t.db");
  $db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
  $db->set_setting('k', 'parent');
  my $pid = fork();
  if (!defined $pid) {
    skip 'no fork', 1;
  }
  elsif ($pid == 0) {

    # In the child: don't emit TAP. Reconnect should happen
    # automatically inside set_setting via dbh()'s pid-check.
    eval {$db->set_setting('k', 'child'); 1} or do {exit 1};
    exit 0;
  }
  else {
    waitpid $pid, 0;
    is($?, 0, 'child exited cleanly');

    # Reopen our own handle to see the WAL-committed value.
    $db->reconnect;
    is($db->setting('k'), 'child', 'child write visible after fork');
  }
}

# 8. TeX renderer emits a transparent PNG, not inline SVG. Removes the
#    whole class of "evil tex makes scriptable SVG" attack surface.
SKIP: {
  skip 'no latex/dvisvgm', 2
    unless `which latex   2>/dev/null` =~ /\S/
    && `which dvisvgm 2>/dev/null` =~ /\S/;
  my $tmpdir = File::Temp->newdir;
  mkdir "$tmpdir/scratch";
  my $db = Iczelia::DB->connect("$tmpdir/t.db");
  $db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
  my $tex = Iczelia::Tex->new(db => $db, tmp_dir => "$tmpdir/scratch");
  my $h   = $tex->render(0, 'x^2');
  unlike(
    $h,
    qr/<svg|<script|onerror=|onload=/i,
    'no inline SVG / event handlers in math output'
  );
  like($h, qr{<img\b[^>]*src="data:image/svg\+xml;base64,}, 'SVG data URL');
}

done_testing;
