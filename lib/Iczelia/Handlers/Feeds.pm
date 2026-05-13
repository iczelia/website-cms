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

package Iczelia::Handlers::Feeds;
use strict;
use warnings;
use utf8;
use Iczelia::HTTP   ();
use Iczelia::Util   qw(escape_html);
use Iczelia::Time   qw(fmt_iso http_date_of);
use Iczelia::Markup ();
use Iczelia::Handlers::Honeypot ();

use constant FEED_ITEMS_LIMIT => 30;

# Feeds: Atom (/feed.xml), RSS 2.0 (/index.xml, /rss.xml), sitemap, and
# a minimal robots.txt. Bodies render through Markup but math placeholders
# become literal "[math]" so we don't bloat feed content with PNGs.

sub register {
  my ($class, $router, $ctx) = @_;
  $router->get('/feed.xml',    sub {_feed($ctx)});
  $router->get('/index.xml',   sub {_rss($ctx)});       # RSS 2.0
  $router->get('/rss.xml',     sub {_rss($ctx)});       # alias
  $router->get('/sitemap.xml', sub {_sitemap($ctx)});
  $router->get('/robots.txt',  sub {_robots($ctx)});
}

sub _setting {
  my ($db, $k, $default) = @_;
  my $v = $db->one('SELECT value FROM settings WHERE key=?', $k);
  return defined $v && length $v ? $v : $default;
}

sub _base_url {
  my ($db) = @_;
  my $u = _setting($db, 'site.base_url', 'https://iczelia.net');
  $u =~ s{/+$}{};
  return $u;
}

sub _feed {
  my ($ctx)  = @_;
  my $db     = $ctx->db;
  my $base   = _base_url($db);
  my $title  = _setting($db, 'site.title',  'iczelia');
  my $author = _setting($db, 'site.author', 'iczelia');
  my $email  = _setting($db, 'site.email',  '');

  my $rows = $db->all(
    q{
        SELECT slug, title, date, body, rendered_html, updated_at
        FROM posts
        WHERE kind='blog' AND draft=0
          AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC, created_at DESC, id DESC LIMIT } . FEED_ITEMS_LIMIT
  );

  my $latest_ts = 0;
  for my $r (@$rows) {
    $latest_ts = $r->{updated_at} if $r->{updated_at} > $latest_ts;
  }
  $latest_ts ||= time;

  my $self_url = "$base/feed.xml";

  my @bits;
  push @bits, '<?xml version="1.0" encoding="utf-8"?>';
  push @bits, '<feed xmlns="http://www.w3.org/2005/Atom">';
  push @bits, '<title>' . escape_html($title) . '</title>';
  push @bits, '<id>' . escape_html("$base/") . '</id>';
  push @bits, '<link rel="alternate" type="text/html" href="'
    . escape_html("$base/blog/") . '"/>';
  push @bits, '<link rel="self" type="application/atom+xml" href="'
    . escape_html($self_url) . '"/>';
  push @bits, '<updated>' . fmt_iso($latest_ts) . '</updated>';
  push @bits,
      '<author><name>'
    . escape_html($author)
    . '</name>'
    . ($email ? '<email>' . escape_html($email) . '</email>' : '')
    . '</author>';

  for my $r (@$rows) {
    my $url = "$base/blog/$r->{slug}/";

    # rendered_html includes the full page chrome - too much for a
    # feed. Re-run just the body through Markup, no Tex.
    my $content;
    if (defined $r->{rendered_html} && length $r->{rendered_html}) {
      my ($html) = Iczelia::Markup::render($r->{body} // '');
      $html =~ s/__MATH(\d+)__/[math]/g;
      $content = $html;
    }
    else {
      $content = '<pre>' . escape_html($r->{body} // '') . '</pre>';
    }
    push @bits, '<entry>';
    push @bits, '<title>' . escape_html($r->{title}) . '</title>';
    push @bits, '<id>' . escape_html($url) . '</id>';
    push @bits, '<link rel="alternate" type="text/html" href="'
      . escape_html($url) . '"/>';
    push @bits, '<published>' . _atom_date($r->{date}) . '</published>';
    push @bits, '<updated>' . fmt_iso($r->{updated_at}) . '</updated>';
    push @bits, '<content type="html">';
    push @bits, '<![CDATA[' . _cdata_escape($content) . ']]>';
    push @bits, '</content>';
    push @bits, '</entry>';
  }
  push @bits, '</feed>';

  return {
    status  => 200,
    headers => {'Content-Type' => 'application/atom+xml; charset=utf-8'},
    body    => join("\n", @bits) . "\n",
  };
}

sub _atom_date {
  my $d = shift // '';
  if ($d =~ /^(\d{4})-(\d{2})-(\d{2})/) {
    return "$1-$2-${3}T00:00:00Z";
  }
  return $d;
}

# Split any literal `]]>` across two CDATA sections; without this, a
# code block containing `]]>` would terminate the surrounding CDATA and
# let arbitrary feed markup follow.
sub _cdata_escape {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ s/\]\]>/]]]]><![CDATA[>/g;
  return $s;
}

sub _rss_date_from_iso {
  my $d = shift // '';
  return $d unless $d =~ /^(\d{4})-(\d{2})-(\d{2})/;
  require Time::Local;
  return http_date_of(Time::Local::timegm(0, 0, 0, $3, $2 - 1, $1));
}

sub _rss {
  my ($ctx)  = @_;
  my $db     = $ctx->db;
  my $base   = _base_url($db);
  my $title  = _setting($db, 'site.title',  'iczelia');
  my $author = _setting($db, 'site.author', 'iczelia');
  my $email  = _setting($db, 'site.email',  '');

  my $rows = $db->all(
    q{
        SELECT slug, title, date, body, updated_at
        FROM posts
        WHERE kind='blog' AND draft=0
          AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC, created_at DESC, id DESC LIMIT } . FEED_ITEMS_LIMIT
  );

  my $latest_ts = 0;
  for my $r (@$rows) {
    $latest_ts = $r->{updated_at} if $r->{updated_at} > $latest_ts;
  }
  $latest_ts ||= time;

  my @bits;
  push @bits, '<?xml version="1.0" encoding="utf-8"?>';
  push @bits, '<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">';
  push @bits, '<channel>';
  push @bits, '<title>' . escape_html($title) . '</title>';
  push @bits, '<link>' . escape_html("$base/") . '</link>';
  push @bits,
    '<description>' . escape_html("$title - blog feed") . '</description>';
  push @bits, '<language>en</language>';
  push @bits, '<lastBuildDate>' . http_date_of($latest_ts) . '</lastBuildDate>';
  push @bits,
      '<atom:link href="'
    . escape_html("$base/index.xml")
    . '" rel="self" type="application/rss+xml" />';
  push @bits, '<generator>iczelia/0.1</generator>';

  if ($email) {
    push @bits,
        '<managingEditor>'
      . escape_html("$email ($author)")
      . '</managingEditor>';
  }

  for my $r (@$rows) {
    my $url = "$base/blog/$r->{slug}/";
    my ($body_html) = Iczelia::Markup::render($r->{body} // '');
    $body_html =~ s/__MATH(\d+)__/[math]/g;

    push @bits, '<item>';
    push @bits, '<title>' . escape_html($r->{title}) . '</title>';
    push @bits, '<link>' . escape_html($url) . '</link>';
    push @bits, '<guid isPermaLink="true">' . escape_html($url) . '</guid>';
    push @bits, '<pubDate>' . _rss_date_from_iso($r->{date}) . '</pubDate>';
    push @bits,
        '<description><![CDATA['
      . _cdata_escape($body_html)
      . ']]></description>';
    push @bits, '</item>';
  }
  push @bits, '</channel>';
  push @bits, '</rss>';

  return {
    status  => 200,
    headers => {'Content-Type' => 'application/rss+xml; charset=utf-8'},
    body    => join("\n", @bits) . "\n",
  };
}

sub _sitemap {
  my ($ctx) = @_;
  my $db    = $ctx->db;
  my $base  = _base_url($db);

  my @urls = (
    {loc => "$base/",           priority => '1.0'},
    {loc => "$base/about/",     priority => '0.8'},
    {loc => "$base/cv/",        priority => '0.5'},
    {loc => "$base/blog/",      priority => '0.7'},
    {loc => "$base/journal/",   priority => '0.6'},
    {loc => "$base/updates/",   priority => '0.4'},
    {loc => "$base/guestbook/", priority => '0.3'},
    {loc => "$base/webring/",   priority => '0.3'},
  );

  my $blog = $db->all(
    q{
        SELECT slug, updated_at FROM posts
        WHERE kind='blog' AND draft=0
          AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC}
  );
  push @urls, map {
    {
      loc      => "$base/blog/$_->{slug}/",
      lastmod  => fmt_iso($_->{updated_at}),
      priority => '0.6'
    }
  } @$blog;

  my $jour = $db->all(
    q{
        SELECT slug, updated_at FROM posts
        WHERE kind='journal' AND draft=0
          AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC}
  );

  my $dyn = $db->all(
    q{
        SELECT route, updated_at FROM dynamic_pages ORDER BY route}
  );
  push @urls, map {
    {
      loc      => "$base$_->{route}",
      lastmod  => fmt_iso($_->{updated_at}),
      priority => '0.4'
    }
  } @$dyn;
  push @urls, map {
    {
      loc      => "$base/journal/$_->{slug}/",
      lastmod  => fmt_iso($_->{updated_at}),
      priority => '0.5'
    }
  } @$jour;

  my $series = $db->all(
    q{SELECT slug, updated_at FROM series ORDER BY title}
  );
  push @urls, map {
    {
      loc      => "$base/series/$_->{slug}/",
      lastmod  => fmt_iso($_->{updated_at}),
      priority => '0.5'
    }
  } @$series;

  my @bits;
  push @bits, '<?xml version="1.0" encoding="utf-8"?>';
  push @bits, '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">';
  for my $u (@urls) {
    push @bits, '<url>';
    push @bits, '<loc>' . escape_html($u->{loc}) . '</loc>';
    push @bits, '<lastmod>' . $u->{lastmod} . '</lastmod>' if $u->{lastmod};
    push @bits, '<priority>' . $u->{priority} . '</priority>'
      if $u->{priority};
    push @bits, '</url>';
  }
  push @bits, '</urlset>';

  return {
    status  => 200,
    headers => {'Content-Type' => 'application/xml; charset=utf-8'},
    body    => join("\n", @bits) . "\n",
  };
}

sub _robots {
  my ($ctx) = @_;
  my $base = _base_url($ctx->db);
  my $body = "User-agent: *\n";
  $body .= "Disallow: $_\n"
    for ('/admin/', @Iczelia::Handlers::Honeypot::PATHS);
  $body .= "\nSitemap: $base/sitemap.xml\n";
  return {
    status  => 200,
    headers => {'Content-Type' => 'text/plain; charset=utf-8'},
    body    => $body,
  };
}

1;
