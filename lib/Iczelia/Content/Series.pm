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

package Iczelia::Content::Series;
use strict;
use warnings;
use Iczelia::Util qw(slugify);

# Iczelia::Content mixin: post-series (multi-part collections). Pulled
# into the leaf Iczelia::Content via @ISA. $self is an
# Iczelia::Content instance.
# Provides: list_series, get_series, get_series_by_slug, create_series,
#   update_series, delete_series, posts_in_series, series_neighbours.
# Reads $self slots: db, render.

sub list_series {
  my ($self) = @_;
  return $self->{db}->all(
    q{SELECT s.id, s.slug, s.title, s.description, s.updated_at,
             (SELECT COUNT(*) FROM posts p WHERE p.series_id = s.id) AS post_count
        FROM series s ORDER BY s.title}
  );
}

sub get_series {
  my ($self, $id) = @_;
  return $self->{db}->row('SELECT * FROM series WHERE id=?', $id);
}

sub get_series_by_slug {
  my ($self, $slug) = @_;
  return $self->{db}->row('SELECT * FROM series WHERE slug=?', $slug);
}

sub create_series {
  my ($self, $rec) = @_;
  my $title = $rec->{title} // '';
  return (undef, 'title required') unless length $title;
  my $base = $rec->{slug} || slugify($title) || 'untitled-' . time;
  my $slug = $base;
  for (my $i = 2;; $i++) {
    last unless $self->{db}->one('SELECT 1 FROM series WHERE slug=?', $slug);
    $slug = "$base-$i";
    return (undef, 'cannot find free slug') if $i > 1000;
  }
  $self->{db}->do_(
    q{INSERT INTO series(slug, title, description, created_at, updated_at)
        VALUES(?,?,?, strftime('%s','now'), strftime('%s','now'))},
    $slug, $title, $rec->{description} // ''
  );
  return ($self->{db}->last_id, undef);
}

sub update_series {
  my ($self, $id, $rec) = @_;
  my $cur = $self->get_series($id) or return (undef, 'not found');
  my $title = defined $rec->{title} && length $rec->{title}
    ? $rec->{title}
    : $cur->{title};
  my $slug = $cur->{slug};
  if (defined $rec->{slug} && length $rec->{slug} && $rec->{slug} ne $slug) {
    my $base = slugify($rec->{slug});
    return (undef, 'invalid slug') unless length $base;
    my $candidate = $base;
    for (my $i = 2;; $i++) {
      last unless $self->{db}->one(
        'SELECT 1 FROM series WHERE slug=? AND id<>?', $candidate, $id);
      $candidate = "$base-$i";
      return (undef, 'cannot find free slug') if $i > 1000;
    }
    $slug = $candidate;
  }
  $self->{db}->do_(
    q{UPDATE series SET slug=?, title=?, description=?,
                        updated_at=strftime('%s','now') WHERE id=?},
    $slug, $title, $rec->{description} // $cur->{description}, $id
  );
  $self->_bust_series_pages($cur->{slug}, $slug);
  return ($id, undef);
}

sub delete_series {
  my ($self, $id) = @_;
  my $cur = $self->get_series($id) or return;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_(q{UPDATE posts SET series_id=NULL, series_position=NULL
                  WHERE series_id=?}, $id);
      $d->do_('DELETE FROM series WHERE id=?', $id);
    }
  );
  $self->_bust_series_pages($cur->{slug});
}

# Posts in a series, ordered by series_position with NULLs at the end.
sub posts_in_series {
  my ($self, $series_id) = @_;
  return $self->{db}->all(
    q{SELECT id, kind, slug, title, date, series_position, draft, publish_at
        FROM posts
       WHERE series_id = ? AND draft = 0
         AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
       ORDER BY series_position IS NULL, series_position, date, id}, $series_id
  );
}

# Returns ($prev, $next) post hashrefs (or undef) for a post within
# its series. Neighbours are ordered by series_position.
sub series_neighbours {
  my ($self, $series_id, $position) = @_;
  return (undef, undef) unless $series_id && defined $position;
  my $prev = $self->{db}->row(
    q{SELECT kind, slug, title, series_position FROM posts
       WHERE series_id = ? AND series_position < ? AND draft = 0
         AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
       ORDER BY series_position DESC LIMIT 1}, $series_id, $position
  );
  my $next = $self->{db}->row(
    q{SELECT kind, slug, title, series_position FROM posts
       WHERE series_id = ? AND series_position > ? AND draft = 0
         AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
       ORDER BY series_position ASC LIMIT 1}, $series_id, $position
  );
  return ($prev, $next);
}

sub _bust_series_pages {
  my ($self, @slugs) = @_;
  return unless $self->{render};
  my %seen;
  for my $s (grep {defined && length} @slugs) {
    next if $seen{$s}++;
    $self->{render}->invalidate_route("/series/$s/");
  }
  $self->{render}->invalidate_route('/sitemap.xml');
}

1;
