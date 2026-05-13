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

package Iczelia::Handlers::OG;
use strict;
use warnings;
use Iczelia::HTTP ();
use Iczelia::OG   ();
use Iczelia::Time qw(fmt_date);

# Auto-generated Open Graph card per published post.
#   GET /og/blog/<slug>.png
#   GET /og/journal/<slug>.png
# Bytes are cached in response_cache via the normal cache layer (the
# path lives in the cacheable set and the response stamps no `_no_cache`
# flag, so the first request rasterises and subsequent hits read from
# the DB). Cache busts on post update via the normal invalidate_post
# path (we add the og path to the bust list there).

sub register {
  my ($class, $router, $ctx) = @_;
  $router->get('/og/:kind/:slug.png', sub {_serve($ctx, $_[0])});
}

sub _serve {
  my ($ctx, $req) = @_;
  my $kind = $req->{caps}{kind};
  my $slug = $req->{caps}{slug};
  return Iczelia::HTTP::error(404)
    unless ($kind eq 'blog' || $kind eq 'journal')
    && defined $slug && $slug =~ /^[a-z0-9][a-z0-9-]{0,80}$/;

  my $row = $ctx->db->row(
    q{SELECT title, date, kappa FROM posts
       WHERE kind=? AND slug=? AND draft=0
         AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))},
    $kind, $slug
  );
  return Iczelia::HTTP::error(404) unless $row;

  my $author = $ctx->db->one(
    q{SELECT value FROM settings WHERE key='site.author'}) // '';
  my $site = $ctx->db->one(
    q{SELECT value FROM settings WHERE key='site.title'}) // 'iczelia';

  my $png = Iczelia::OG::generate(
    $row->{title},
    author   => $author,
    site     => $site,
    kappa    => (split /\s+/, $row->{kappa} // '')[0],
    subtitle => fmt_date($row->{date}),
  );
  return Iczelia::HTTP::error(503, 'og rasteriser unavailable')
    unless defined $png;

  return {
    status  => 200,
    headers => {
      'Content-Type'  => 'image/png',
      'Cache-Control' => 'public, max-age=86400',
    },
    body => $png,
  };
}

1;
