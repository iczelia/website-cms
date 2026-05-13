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

$c->create_post('blog',
  {title => 'p1', body => 'hi', date => '2026-05-09', tags => 'a'});
$c->create_post('blog',
  {title => 'p2', body => 'hi', date => '2026-05-09', tags => 'a, b'});
$c->create_post('blog',
  {title => 'p3', body => 'hi', date => '2026-05-09', tags => 'b, c'});

# Tag listing for 'a' has p1 + p2.
my $list = $r->_post_list('blog', tag => 'a');
is(scalar(@$list), 2, 'tag a yields two posts');
my @titles = map {$_->{title}} @$list;
is_deeply([sort @titles], ['p1', 'p2'], 'tag a posts are p1 + p2');

# Tag page renders.
my $html = $r->render_tag_page('blog', 'a');
ok($html, 'tag page renders');
like($html, qr/p1/, 'p1 in tag page');
like($html, qr/p2/, 'p2 in tag page');
unlike($html, qr{>p3<}, 'p3 absent from tag a');

# Tag feed renders Atom.
my $xml = $r->render_tag_feed('blog', 'b');
ok($xml, 'tag feed renders');
like($xml, qr{<feed xmlns="http://www.w3.org/2005/Atom">}, 'atom envelope');
like($xml, qr/p2/,                                         'p2 in tag-b feed');
like($xml, qr/p3/,                                         'p3 in tag-b feed');

# Tag with no matching posts returns undef.
is($r->render_tag_feed('blog', 'nonexistent'),
  undef, 'unused tag -> undef feed');

done_testing;
