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

my $now = time;

# 1. publish_at in the future hides the post from public renders.
my $slug = $c->create_post(
  'blog',
  {
    title      => 'future post',
    date       => '2026-05-09',
    body       => 'top secret',
    publish_at => $now + 3600,
  }
);
is($r->render_post('blog', $slug),
  undef, 'render_post returns undef for future-scheduled post');
my $list = Iczelia::Render::_post_list($r, 'blog');
ok(
  !grep({$_->{slug} eq $slug} @$list),
  '_post_list excludes future-scheduled post'
);

# 2. Setting publish_at to the past makes it visible.
$db->do_('UPDATE posts SET publish_at=? WHERE slug=?', $now - 60, $slug);
my $html = $r->render_post('blog', $slug);
ok(defined $html && length $html, 'past-scheduled post renders');

$list = Iczelia::Render::_post_list($r, 'blog');
ok(
  scalar(grep {$_->{slug} eq $slug} @$list),
  '_post_list now includes past-scheduled post'
);

# 3. NULL publish_at + draft=0 -> published.
my $slug2 = $c->create_post(
  'blog',
  {
    title => 'plain',
    date  => '2026-05-09',
    body  => 'whatever',
  }
);
ok(
  defined $r->render_post('blog', $slug2),
  'NULL publish_at -> published immediately'
);

# 4. Validator: blank publish_at OK.
require Iczelia::Handlers::Admin;
my ($rec, $err) = Iczelia::Handlers::Admin::Posts::_validate_post(
  {
    title      => 't',
    body       => 'b',
    date       => '2026-05-09',
    publish_at => '',
  },
  undef
);
ok($rec && !defined $rec->{publish_at}, 'blank publish_at -> undef');

# 5. Validator: past publish_at -> rejected.
($rec, $err) = Iczelia::Handlers::Admin::Posts::_validate_post(
  {
    title      => 't',
    body       => 'b',
    date       => '2026-05-09',
    publish_at => '2020-01-01T00:00',
  },
  undef
);
ok(!$rec, 'past publish_at rejected');
like($err, qr/past/, 'past publish_at error message');

# 6. Validator: future publish_at -> accepted, returned as epoch int.
($rec, $err) = Iczelia::Handlers::Admin::Posts::_validate_post(
  {
    title      => 't',
    body       => 'b',
    date       => '2026-05-09',
    publish_at => '2099-12-31T23:59',
  },
  undef
);
ok($rec && defined $rec->{publish_at}, 'future publish_at accepted');
like($rec->{publish_at}, qr/^\d+$/, 'publish_at is epoch integer');

done_testing;
