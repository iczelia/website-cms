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
like(
  $home,
  qr{<meta name="description" content="The homepage of Kamila Szewczyk \(iczelia\)\.">},
  'home meta description, no blog post yet'
);

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
    {profile => "21, mathematician, **scientist**, programmer."}
  )
);
$db->do_(
  q{INSERT INTO activity(source, text, position, fetched_at)
       VALUES('currently', ?, 0, strftime('%s','now'))},
  'writing about monads'
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
like(
  $home2,
  qr{<meta name="description" content="The homepage of Kamila Szewczyk \(iczelia\)\. Newest blog post: hello world, 04\.20\.2026\.">},
  'home meta description names the newest blog post'
);

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

# 7: Regression - every home-page write path must reach the renderer.
# Each "currently is somewhere else than the renderer reads from" bug
# class manifests as: admin save persists, but render_home doesn't see
# the new value. Sentinel-string each write path so a future split
# fails loudly.
use Iczelia::Content;
my $content = Iczelia::Content->new(db => $db, render => $r);

$content->set_currently('SENTINEL_CURRENTLY_FROM_ACTIVITY');
my $home_cur = $r->render_home;
like($home_cur, qr{SENTINEL_CURRENTLY_FROM_ACTIVITY},
  q{/admin/activity/currently -> activity table -> home renders 'currently'});

$content->save_page('home', 'iczelia :: personal site v2.0',
  'home', $J->encode({profile => 'SENTINEL_PROFILE_FROM_HOMEEDIT'}));
my $home_prof = $r->render_home;
like($home_prof, qr{SENTINEL_PROFILE_FROM_HOMEEDIT},
  q{/admin/edit/home -> pages.data.profile -> home renders 'profile'});

$content->replace_updates(
  [{date => '2026-06-15', body => 'SENTINEL_UPDATE_BODY'}]);
my $home_upd = $r->render_home;
like($home_upd, qr{SENTINEL_UPDATE_BODY},
  q{/admin/updates/ -> updates table -> home renders update body});

# 8: {{age}} in the profile blurb resolves to the site.age setting.
# A fresh Render sidesteps the 60s settings memo on $r.
$db->do_(
  q{INSERT INTO settings(key,value) VALUES('site.age',?)
       ON CONFLICT(key) DO UPDATE SET value=excluded.value}, '23'
);
$content->save_page('home', 'iczelia :: personal site v2.0',
  'home', $J->encode({profile => '{{ age }}, mathematician, programmer'}));
my $home_age = Iczelia::Render->new(db => $db, template => $tpl)->render_home;
like($home_age, qr{23, mathematician, programmer},
  q{/admin/settings/ site.age -> home expands {{age}}});
unlike($home_age, qr/\{\{\s*age\s*\}\}/, 'no literal placeholder survives');

done_testing;
