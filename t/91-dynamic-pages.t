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
use JSON::PP ();

use Iczelia::DB;
use Iczelia::Template;
use Iczelia::Render;
use Iczelia::Content;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/test.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->apply_schema_file("$FindBin::Bin/../share/seed.sql");

my $tpl = Iczelia::Template->new(dirs => ["$FindBin::Bin/../share/templates"]);
my $r   = Iczelia::Render->new(db => $db, template => $tpl);
my $c   = Iczelia::Content->new(db => $db, render => $r);

# 1. Validate routes.
my ($r1, $e1) = Iczelia::Content::validate_dynamic_route('/zine/');
is($r1, '/zine/', 'simple route accepted');
ok(!$e1, 'no error');

my ($r2, $e2) = Iczelia::Content::validate_dynamic_route('/about/now/');
is($r2, '/about/now/', 'two-segment route accepted');

my ($r3, $e3) = Iczelia::Content::validate_dynamic_route('/foo');
ok(!$r3, 'missing trailing slash rejected');
like($e3, qr/invalid/, 'invalid');

my ($r4, $e4) = Iczelia::Content::validate_dynamic_route('/admin/foo/');
ok(!$r4, 'reserved prefix rejected');
like($e4, qr/reserved/, 'reserved error');

my ($r5, $e5) = Iczelia::Content::validate_dynamic_route('/Blog/');
ok(!$r5, 'uppercase rejected');

# 2. CRUD.
my $J = JSON::PP->new->utf8(0)->canonical(1);
my ($id, $err) = $c->create_dynamic_page(
  {
    route => '/zine/',
    title => 'Zine',
    data  => $J->encode({intro => 'Welcome', body => '# hi'}),
  }
);
ok($id,   'create_dynamic_page returns id');
ok(!$err, 'no error');

my $row = $c->get_dynamic_page_by_route('/zine/');
ok($row, 'lookup by route');
is($row->{title}, 'Zine', 'title roundtrip');

# Trying to create a duplicate route fails.
my ($id2, $err2) = $c->create_dynamic_page(
  {
    route => '/zine/',
    title => 'oops',
    data  => $J->encode({}),
  }
);
ok(!$id2, 'duplicate rejected');
like($err2, qr/exists/, 'duplicate err');

# 3. Render the dynamic page.
my $html = $r->render_dynamic('/zine/');
ok(defined $html && length $html, 'render_dynamic returns HTML');
like($html, qr/Zine/,         'title in output');
like($html, qr/<h1[^>]*>hi/i, 'body markdown rendered');

# 4. Update the route.
my ($_id, $err3) = $c->update_dynamic_page(
  $id,
  {
    route => '/lab/',
    title => 'Lab',
    data  => $J->encode({body => 'lab notes'}),
  }
);
ok(!$err3, 'rename succeeded') or diag $err3;
my $row2 = $c->get_dynamic_page_by_route('/lab/');
ok($row2, 'new route resolves');
is($c->get_dynamic_page_by_route('/zine/'), undef, 'old route gone');

# 5. Delete.
$c->delete_dynamic_page($id);
is($c->get_dynamic_page_by_route('/lab/'), undef, 'deleted');

done_testing;
