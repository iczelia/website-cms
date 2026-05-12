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

# <head> SEO/social metadata: canonical URLs, meta description,
# Open Graph, Twitter card, article timestamps, robots directives.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Template;
use Iczelia::Render;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->apply_schema_file("$FindBin::Bin/../share/seed.sql");

# A blog post with tags and a body long enough to exercise truncation.
$db->do_(
  q{INSERT INTO posts(kind, slug, title, date, body, tags, draft,
                      word_count, created_at, updated_at)
    VALUES('blog','constant-overhead','Measuring Constant Overhead',
           '2024-06-15', ?,
           'java, python, benchmark', 0, 40, 1718000000, 1718459841)},
  q{Lorem Ipsum is simply dummy text of the printing and typesetting industry. Lorem Ipsum has been the industry's standard dummy text ever since the 1500s, when an unknown printer took a galley of type and scrambled it to make a type specimen book. It has survived not only five centuries, but also the leap into electronic typesetting, remaining essentially unchanged. It was popularised in the 1960s with the release of Letraset sheets containing Lorem Ipsum passages, and more recently with desktop publishing software like Aldus PageMaker including versions of Lorem Ipsum.}
);

my $tpl = Iczelia::Template->new(dirs => ["$FindBin::Bin/../share/templates"]);
my $r   = Iczelia::Render->new(db => $db, template => $tpl);

sub head_of {
  my ($html) = @_;
  my ($h) = $html =~ m{<head>(.*?)</head>}s;
  return $h // '';
}

{
  my $h = head_of($r->render_home);
  like($h, qr{<link rel="canonical" href="https://iczelia\.net/">},
    'home: absolute canonical');
  like($h, qr{<meta name="description" content="[^"]+">}, 'home: description present');
  like($h, qr{<meta name="twitter:card" content="summary">}, 'home: twitter card');
  like($h, qr{<meta property="og:type" content="website">},  'home: og:type website');
  like($h, qr{<meta property="og:url" content="https://iczelia\.net/">}, 'home: og:url');
  like($h, qr{<meta property="og:site_name" content="iczelia">}, 'home: og:site_name');
  unlike($h, qr{article:published_time}, 'home: no article timestamps');
}

{
  my $h = head_of($r->render_page('about'));
  like($h, qr{<link rel="canonical" href="https://iczelia\.net/about/">},
    'about: canonical points at /about/');
  like($h, qr{<meta property="og:type" content="website">}, 'about: og:type website');
}

{
  my $h = head_of($r->render_post('blog', 'constant-overhead'));
  like($h, qr{<link rel="canonical" href="https://iczelia\.net/blog/constant-overhead/">},
    'post: canonical');
  like($h, qr{<meta property="og:type" content="article">}, 'post: og:type article');
  like($h, qr{<meta property="og:title" content="Measuring Constant Overhead">},
    'post: og:title is the bare post title (no site prefix)');
  like($h, qr{<meta name="keywords" content="java, python, benchmark">},
    'post: keywords from tags');
  like($h, qr{<meta property="article:published_time" content="2024-06-15">},
    'post: published_time');
  like($h, qr{<meta property="article:modified_time" content="\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z">},
    'post: modified_time from updated_at');
  my ($desc) = $h =~ m{<meta name="description" content="([^"]*)">};
  ok(defined $desc && length($desc) <= 165 && $desc =~ /\.\.\.$/,
    'post: description truncated with an ellipsis')
    or diag("desc=[$desc] len=" . length($desc // ''));
  like($desc, qr/^Lorem Ipsum is simply dummy text/, 'post: description starts from the body text');
}

{
  my $h = head_of($r->render_not_found({path => '/nope/'}));
  like($h, qr{<meta name="robots" content="noindex,nofollow">}, '404: robots noindex');
  unlike($h, qr{<link rel="canonical"}, '404: no canonical');
}

{
  my $idx = head_of($r->render_blog_index);
  like($idx, qr{<link rel="canonical" href="https://iczelia\.net/blog/">},
    'blog index: canonical is /blog/');
  my $yr = head_of($r->render_blog_year(2024));
  like($yr, qr{<link rel="canonical" href="https://iczelia\.net/blog/year/2024/">},
    'blog year page: canonical is the year URL');
}

{
  $db->set_setting('site.base_url', '');

  # render_home is never cached, so the new setting takes effect at once.
  my $r2 = Iczelia::Render->new(db => $db, template => $tpl);
  my $h  = head_of($r2->render_home);
  like($h, qr{<link rel="canonical" href="/">},
    'no base_url: canonical falls back to a root-relative path');
  like($h, qr{<meta property="og:url" content="/">}, 'no base_url: og:url likewise');
}

done_testing;
