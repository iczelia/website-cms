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

package Iczelia::Render::Invalidate;
use strict;
use warnings;

# Iczelia::Render mixin: cache-bust helpers. Pulled into the leaf
# Iczelia::Render via @ISA. $self is an Iczelia::Render instance.
# Provides: invalidate_page, invalidate_post, invalidate_home,
#   invalidate_route, invalidate_all; private _bust_for_page.
# Reads $self slots: db, cache.

sub invalidate_page {
  my ($self, $slug) = @_;
  $self->{db}->do_(q{UPDATE pages SET rendered_html=NULL WHERE slug=?}, $slug);
  $self->_bust_for_page($slug);
}

sub invalidate_route {
  my ($self, $path) = @_;
  return unless defined $path && length $path;
  return unless $self->{cache};
  $self->{cache}->bust($path);
}

sub invalidate_post {
  my ($self, $kind, $slug) = @_;
  $self->{db}
    ->do_(q{UPDATE posts SET rendered_html=NULL WHERE kind=? AND slug=?},
    $kind, $slug);
  return unless $self->{cache};
  $self->{cache}->bust_many(
    "/$kind/$slug/", "/$kind/",    "/$kind/tags/", '/',
    '/feed.xml',     '/index.xml', '/sitemap.xml',
  );
  $self->{cache}->bust_prefix("/$kind/tag/");
}

sub invalidate_home {$_[0]->invalidate_page('home')}

# Wholesale wipe; used after settings changes and as a manual reset.
sub invalidate_all {
  my ($self) = @_;
  return unless $self->{cache};
  $self->{cache}->bust_all;
}

# URLs that go stale when a given CMS page changes.
sub _bust_for_page {
  my ($self, $slug) = @_;
  return unless $self->{cache};
  my @urls;
  if ($slug eq 'home') {
    @urls = ('/', '/feed.xml', '/index.xml', '/sitemap.xml');
  }
  elsif ($slug eq 'blog' || $slug eq 'journal') {
    @urls = (
      "/$slug/",    "/$slug/tags/", '/', '/feed.xml',
      '/index.xml', '/sitemap.xml'
    );
    $self->{cache}->bust_prefix("/$slug/tag/");
  }
  elsif ($slug eq 'webring'
    || $slug eq 'updates'
    || $slug eq 'guestbook'
    || $slug eq 'about'
    || $slug eq 'cv')
  {
    @urls = ("/$slug/", '/', '/sitemap.xml');
  }
  else {
    @urls = ("/$slug/", '/sitemap.xml');
  }
  $self->{cache}->bust_many(@urls);
}

1;
