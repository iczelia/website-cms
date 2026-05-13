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

package Iczelia::Handlers::Public;
use strict;
use warnings;
use Iczelia::HTTP ();
use Iczelia::Util qw(escape_url split_tags);

use constant SEARCH_RESULTS_LIMIT => 30;

sub register {
  my ($class, $router, $ctx) = @_;
  $router->get('/',                 sub {_home($ctx, @_)});
  $router->get('/about/',           sub {_page($ctx, 'about')});
  $router->get('/cv/',              sub {_page($ctx, 'cv')});
  $router->get('/blog/',            sub {_blog_index($ctx)});
  $router->get('/blog/year/:year/', sub {_blog_year($ctx, $_[0])});
  $router->get('/blog/tags/',       sub {_tag_index($ctx, 'blog')});
  $router->get('/blog/tag/:tag/',   sub {_tag_page($ctx, 'blog', $_[0])});
  $router->get('/blog/tag/:tag/feed.xml',
    sub {_tag_feed($ctx, 'blog', $_[0])});
  $router->get('/journal/',            sub {_journal_index($ctx)});
  $router->get('/journal/year/:year/', sub {_journal_year($ctx, $_[0])});
  $router->get('/journal/tags/',       sub {_tag_index($ctx, 'journal')});
  $router->get('/journal/tag/:tag/', sub {_tag_page($ctx, 'journal', $_[0])});
  $router->get('/journal/tag/:tag/feed.xml',
    sub {_tag_feed($ctx, 'journal', $_[0])});
  $router->get('/webring/',       sub {_page($ctx, 'webring')});
  $router->get('/guestbook/',     sub {_page($ctx, 'guestbook')});
  $router->get('/updates/',       sub {_updates($ctx)});
  $router->get('/search/',        sub {_search($ctx, $_[0])});
  $router->get('/blog/:slug/',    sub {_post($ctx, 'blog',    $_[0])});
  $router->get('/journal/:slug/', sub {_post($ctx, 'journal', $_[0])});

  # Legacy /posts/<slug>/ alias - 301 to the canonical /<kind>/<slug>/
  # so external links and search-engine results keep working.
  $router->get('/posts/:slug/', sub {_posts_alias($ctx, $_[0])});
  $router->get('/healthz',      sub {Iczelia::HTTP::text('ok')});
}

sub _home {
  my ($ctx, $req) = @_;
  my $html = $ctx->{render}->render_home;
  my $resp = Iczelia::HTTP::html($html,
    headers => {'Cache-Control' => 'no-store'});
  $resp->{_no_cache} = 1;
  return $resp;
}

sub _page {
  my ($ctx, $slug, $req) = @_;
  my %opt;
  if ($req && defined $req->{qparams}{tag}) {
    my $t = $req->{qparams}{tag};
    if ($t =~ /^[\w .+-]{1,40}$/) {
      $opt{tag} = $t;
    }
  }
  my $html = $ctx->{render}->render_page($slug, %opt);
  return Iczelia::HTTP::error(404) unless defined $html;
  return Iczelia::HTTP::html($html);
}

sub _updates {
  my ($ctx) = @_;
  my $html = $ctx->{render}->render_updates_full;
  return Iczelia::HTTP::html($html);
}

sub _journal_index {
  my ($ctx) = @_;
  my $html = $ctx->{render}->render_journal_index;
  return Iczelia::HTTP::error(404) unless defined $html;
  return Iczelia::HTTP::html($html);
}

sub _journal_year {
  my ($ctx, $req) = @_;
  my $year = $req->{caps}{year};
  return Iczelia::HTTP::error(404)
    unless defined $year && $year =~ /^\d{4}$/;
  my $html = $ctx->{render}->render_journal_year($year);
  return Iczelia::HTTP::error(404) unless defined $html;
  return Iczelia::HTTP::html($html);
}

sub _blog_index {
  my ($ctx) = @_;
  my $html = $ctx->{render}->render_blog_index;
  return Iczelia::HTTP::error(404) unless defined $html;
  return Iczelia::HTTP::html($html);
}

sub _blog_year {
  my ($ctx, $req) = @_;
  my $year = $req->{caps}{year};
  return Iczelia::HTTP::error(404)
    unless defined $year && $year =~ /^\d{4}$/;
  my $html = $ctx->{render}->render_blog_year($year);
  return Iczelia::HTTP::error(404) unless defined $html;
  return Iczelia::HTTP::html($html);
}

sub _post {
  my ($ctx, $kind, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $html = $ctx->{render}->render_post($kind, $slug);
  if (!defined $html) {

    # If the slug was renamed, the alias table maps it to the
    # current canonical slug; 301 to the live URL.
    my $row = $ctx->{db}->row(
      q{SELECT p.slug FROM post_aliases a
                JOIN posts p ON p.id = a.post_id
               WHERE a.kind=? AND a.from_slug=?
                 AND p.draft=0
                 AND (p.publish_at IS NULL OR p.publish_at <= strftime('%s','now'))},
      $kind, $slug
    );
    if ($row && $row->{slug} ne $slug) {
      return Iczelia::HTTP::redirect("/$kind/$row->{slug}/", status => 301);
    }
    return Iczelia::HTTP::error(404);
  }
  return Iczelia::HTTP::html($html);
}

# 301 /posts/<slug>/ to the canonical /<kind>/<slug>/ - search across
# blog and journal, then fall back to the alias table for old slugs.
sub _posts_alias {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  return Iczelia::HTTP::error(404) unless defined $slug && length $slug;
  my $row = $ctx->{db}->row(
    q{SELECT kind FROM posts WHERE slug=? AND draft=0
            AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
          ORDER BY (kind='blog') DESC LIMIT 1}, $slug
  );
  if ($row) {
    return Iczelia::HTTP::redirect("/$row->{kind}/$slug/", status => 301);
  }
  my $aliased = $ctx->{db}->row(
    q{SELECT a.kind, p.slug FROM post_aliases a
            JOIN posts p ON p.id = a.post_id
           WHERE a.from_slug=? AND p.draft=0
             AND (p.publish_at IS NULL OR p.publish_at <= strftime('%s','now'))
        ORDER BY (a.kind='blog') DESC LIMIT 1}, $slug
  );
  if ($aliased) {
    return Iczelia::HTTP::redirect("/$aliased->{kind}/$aliased->{slug}/",
      status => 301);
  }
  return Iczelia::HTTP::error(404);
}

sub _search {
  my ($ctx, $req) = @_;
  my $q = substr($req->{qparams}{q} // '', 0, 100);

  # Strip to alnum runs and quote each token: FTS5 operators (NEAR,
  # parens, etc.) can't leak through. Implicit AND between tokens.
  my @tok;
  while ($q =~ /([\p{L}\p{N}]+)/g) {
    push @tok, $1 if length $1 >= 2;
    last if @tok >= 8;
  }
  my @results;
  if (@tok) {
    my $match = join ' ', map {qq{"$_"}} @tok;
    my $rows  = eval {
      $ctx->{db}->all(
        q{SELECT slug, kind, title,
                         snippet(posts_fts, 3, '<mark>', '</mark>', '...', 24) AS sn,
                         bm25(posts_fts) AS rank
                    FROM posts_fts
                   WHERE posts_fts MATCH ?
                     AND kind IN ('blog','journal')
                ORDER BY rank LIMIT } . SEARCH_RESULTS_LIMIT, $match
      );
    } || [];
    $_->{url} = "/$_->{kind}/$_->{slug}/" for @$rows;
    @results = @$rows;
  }
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/search.tpl',
      $ctx->{render}->base_vars(
        title => 'iczelia :: search',
        meta  => {
          robots      => 'noindex,follow',
          description  => 'Search the blog and journal.',
        },
        q           => $q,
        results     => \@results,
        empty_query => (@tok ? 0 : 1),
      )
    )
  );
}

sub _tag_index {
  my ($ctx, $kind) = @_;
  my $rows = $ctx->{db}->all(
    q{SELECT tags FROM posts
           WHERE kind=? AND draft=0
             AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))},
    $kind
  );
  my %count;
  for my $r (@$rows) {
    $count{$_}++ for split_tags($r->{tags});
  }
  my @list = map +{
    tag   => $_,
    count => $count{$_},
    url   => "/$kind/tag/" . escape_url($_) . '/'
    },
    sort {$count{$b} <=> $count{$a} || $a cmp $b}
    keys %count;
  my $vars = $ctx->{render}->base_vars(
    title => "iczelia :: $kind tags",
    meta  => {
      canonical   => "/$kind/tags/",
      description  => "All $kind tags.",
    },
    kind => $kind,
    tags => \@list,
  );
  return Iczelia::HTTP::html(
    $ctx->{template}->render('views/tag_index.tpl', $vars));
}

sub _tag_page {
  my ($ctx, $kind, $req) = @_;
  my $tag = $req->{caps}{tag};
  return Iczelia::HTTP::error(404)
    unless defined $tag && $tag =~ /^[\w .+-]{1,40}$/;
  my $html = $ctx->{render}->render_tag_page($kind, $tag);
  return Iczelia::HTTP::error(404) unless defined $html;
  return Iczelia::HTTP::html($html);
}

sub _tag_feed {
  my ($ctx, $kind, $req) = @_;
  my $tag = $req->{caps}{tag};
  return Iczelia::HTTP::error(404)
    unless defined $tag && $tag =~ /^[\w .+-]{1,40}$/;
  my $xml = $ctx->{render}->render_tag_feed($kind, $tag);
  return Iczelia::HTTP::error(404) unless defined $xml;
  return {
    status  => 200,
    headers => {'Content-Type' => 'application/atom+xml; charset=utf-8'},
    body    => $xml,
  };
}

1;
