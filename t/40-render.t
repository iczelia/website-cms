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

my $tmpdir = File::Temp->newdir;
my $dbpath = "$tmpdir/test.db";

my $db = Iczelia::DB->connect($dbpath);
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->apply_schema_file("$FindBin::Bin/../share/seed.sql");

my $tpl =
  Iczelia::Template->new(dirs => ["$FindBin::Bin/../share/templates"],);
my $r = Iczelia::Render->new(db => $db, template => $tpl);

# 1: Home renders even when all content is empty.
my $home = $r->render_home;
ok(length $home > 1000, 'home page is non-trivial');
like($home, qr{<title>iczelia :: personal site v2.0</title>}, 'home title');
like($home, qr{class="nav-box"},                              'home nav');
like($home, qr{:: updates ::},         'home updates pane');
like($home, qr{:: recent activity ::}, 'home activity pane');
like($home, qr{class="clock"},         'home clock');

# 2: About renders chrome.
my $about = $r->render_page('about');
ok(defined $about, 'about exists');
like($about, qr{<title>iczelia :: about</title>}, 'about title');
like($about, qr{class="ab-vitals"},               'about vitals table');
like($about, qr{href="/about/"},                  'about nav link');

# 3: Populate content; home re-renders with it.
my $J = JSON::PP->new->canonical;
$db->do_(
  q{UPDATE pages SET data=?, rendered_html=NULL WHERE slug='home'},
  $J->encode(
    {
      profile   => "21, mathematician, **scientist**, programmer.",
      currently => "writing about monads",
    }
  )
);
$db->do_(
  q{INSERT INTO updates(date, body, position) VALUES(?,?,?)}, '2026-04-21',
  'A monad is a monoid in the category of endofunctors.',     0
);
$db->do_(
  q{INSERT INTO posts(kind, slug, title, date, body, updated_at)
           VALUES('blog','hello','hello world','2026-04-20','# hi',
                  strftime('%s','now'))}
);

my $home2 = $r->render_home;
like($home2, qr{<strong>scientist</strong>}, 'home renders profile markdown');
like($home2, qr{writing about monads},       'home shows currently');
like($home2, qr{04\.21\.2026},               'home shows update date');
like($home2, qr{A monad is a monoid},        'home shows update body');
like($home2, qr{hello world},                'home shows blog teaser');

# 4: Cache works: edit body, html stays unchanged unless invalidated.
my $cached = $r->render_home;
is($cached, $home2, 'second render hits cache, identical output');

$r->invalidate_home;
$db->do_(q{UPDATE updates SET body=? WHERE date='2026-04-21'},
  'a different update');
my $home3 = $r->render_home;
unlike($home3, qr{A monad is a monoid}, 'old update text gone');
like($home3, qr{a different update}, 'new update text present');

# 5: Post render.
my $post = $r->render_post('blog', 'hello');
ok(defined $post, 'post renders');
like($post, qr{<title>iczelia :: hello world</title>}, 'post title');

# 6: 404 paths.
is($r->render_page('does-not-exist'), undef, 'unknown page slug => undef');
is($r->render_post('blog', 'none'),   undef, 'unknown post slug => undef');

done_testing;
