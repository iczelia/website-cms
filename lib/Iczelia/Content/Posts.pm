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

package Iczelia::Content::Posts;
use strict;
use warnings;
use Carp          qw(croak);
use Iczelia::Util qw(slugify split_tags);

# Iczelia::Content mixin: post CRUD + revisions + aliases. Pulled
# into the leaf Iczelia::Content via @ISA. $self is an Iczelia::Content
# instance.
# Provides: get_post, list_posts, create_post, update_post, delete_post,
#   list_aliases, list_revisions, get_revision, delete_alias,
#   normalize_publish_at (public; called from Handlers/Admin/Posts.pm),
#   _word_count (private to this file).
# Reads $self slots: db, render.

sub get_post {
  my ($self, $kind, $slug) = @_;
  return $self->{db}
    ->row('SELECT * FROM posts WHERE kind=? AND slug=?', $kind, $slug);
}

sub list_posts {
  my ($self, $kind, %opt) = @_;
  my $sql = 'SELECT id, slug, title, date, tags, draft, publish_at, updated_at
               FROM posts WHERE kind=?';
  $sql .= ' AND draft=0' if $opt{published_only};
  $sql .= ' ORDER BY date DESC, created_at DESC, id DESC';
  return $self->{db}->all($sql, $kind);
}

sub create_post {
  my ($self, $kind, $rec) = @_;
  my $base = $rec->{slug} || slugify($rec->{title}) || 'untitled-' . time;
  my $body = $rec->{body} // '';
  my $publish_at = normalize_publish_at($rec->{publish_at});
  my $series_id  = _opt_int($rec->{series_id});
  my $series_pos = _opt_int($rec->{series_position});

  # INSERT OR IGNORE in a loop avoids the SELECT-then-INSERT race that
  # otherwise lets two concurrent creators both pass the uniqueness
  # check and collide on the UNIQUE(kind,slug) constraint.
  my $slug = $base;
  for (my $i = 2;; $i++) {
    my $rows = $self->{db}->do_(
      q{
            INSERT OR IGNORE INTO posts(kind, slug, title, date, tags, draft,
                              body, word_count, publish_at,
                              kappa,
                              series_id, series_position,
                              created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                   strftime('%s','now'), strftime('%s','now'))},
      $kind,              $slug, $rec->{title}, $rec->{date},
      $rec->{tags} // '', $rec->{draft} ? 1 : 0,
      $body,              _word_count($body), $publish_at,
      $rec->{kappa} // '',
      $series_id,         $series_pos
    );
    last if $rows;
    $slug = "$base-$i";
    croak "create_post: cannot find a free slug" if $i > 1000;
  }
  $self->{render}->invalidate_post($kind, $slug);
  $self->{render}->invalidate_page($kind);
  $self->{render}->invalidate_home;
  $self->_bust_series($series_id) if $series_id;
  return $slug;
}

sub _opt_int {
  my ($v) = @_;
  return undef unless defined $v && $v ne '';
  return undef unless $v =~ /\A-?\d+\z/;
  return $v + 0;
}

sub _bust_series {
  my ($self, $series_id) = @_;
  return unless $series_id && $self->{render};
  my $row = $self->{db}->row('SELECT slug FROM series WHERE id=?', $series_id);
  return unless $row;
  $self->{render}->invalidate_route("/series/$row->{slug}/");
}

sub update_post {
  my ($self, $kind, $old_slug, $rec) = @_;
  my $base       = $rec->{slug} || $old_slug;
  my $body       = $rec->{body} // '';
  my $publish_at = normalize_publish_at($rec->{publish_at});
  my $series_id  = _opt_int($rec->{series_id});
  my $series_pos = _opt_int($rec->{series_position});

  # Slug uniqueness is resolved INSIDE tx_immediate so two concurrent
  # renames to the same target serialize and one suffixes correctly.
  my $new_slug;
  $self->{db}->tx_immediate(
    sub {
      my $d = shift;
      $new_slug = $base;
      if ($new_slug ne $old_slug) {
        for (my $i = 2;; $i++) {
          last
            unless $d->one('SELECT 1 FROM posts WHERE kind=? AND slug=?',
            $kind, $new_slug);
          $new_slug = "$base-$i";
          croak "update_post: cannot find a free slug" if $i > 1000;
        }
      }
      my $cur = $d->row('SELECT * FROM posts WHERE kind=? AND slug=?',
        $kind, $old_slug);
      if ($cur) {
        my $next = $d->one(
          'SELECT COALESCE(MAX(revision_num),0)+1
                   FROM post_revisions WHERE post_id=?', $cur->{id}
        );
        $d->do_(
          q{
                INSERT INTO post_revisions(
                    post_id, revision_num, title, body, tags, date,
                    draft, publish_at, author, created_at)
                VALUES(?,?,?,?,?,?,?,?,?, strftime('%s','now'))},
          $cur->{id},         $next,        $cur->{title}, $cur->{body},
          $cur->{tags},       $cur->{date}, $cur->{draft},
          $cur->{publish_at}, $rec->{author}
        );
        $d->do_(
          q{
                DELETE FROM post_revisions
                 WHERE post_id=?
                   AND revision_num <=
                       (SELECT MAX(revision_num) - 50
                          FROM post_revisions WHERE post_id=?)},
          $cur->{id}, $cur->{id}
        );
        if ($new_slug ne $old_slug) {
          $d->do_(
            q{
                    INSERT OR REPLACE INTO post_aliases(
                        kind, from_slug, post_id, created_at)
                    VALUES(?,?,?, strftime('%s','now'))},
            $kind, $old_slug, $cur->{id}
          );
        }
      }
      $d->do_(
        q{
            UPDATE posts
               SET slug=?, title=?, date=?, tags=?, draft=?, body=?,
                   word_count=?, publish_at=?, kappa=?,
                   series_id=?, series_position=?,
                   rendered_html=NULL,
                   updated_at=strftime('%s','now')
             WHERE kind=? AND slug=?},
        $new_slug,             $rec->{title}, $rec->{date}, $rec->{tags} // '',
        $rec->{draft} ? 1 : 0, $body,
        _word_count($body),    $publish_at,
        $rec->{kappa} // '',
        $series_id,            $series_pos,
        $kind,                 $old_slug
      );
    }
  );
  if ($new_slug ne $old_slug) {
    $self->{render}->invalidate_post($kind, $old_slug);
  }
  $self->{render}->invalidate_post($kind, $new_slug);
  $self->_bust_series($series_id) if $series_id;
  $self->{render}->invalidate_page($kind);
  $self->{render}->invalidate_home;
  return $new_slug;
}

sub delete_post {
  my ($self, $kind, $slug) = @_;

  # All three deletes are wrapped so a crash mid-way doesn't leave
  # orphaned aliases/revisions. Explicit deletes mirror the CASCADE
  # for tooling that opens the DB without foreign_keys.
  $self->{db}->tx_immediate(
    sub {
      my $d = shift;
      my $row =
        $d->row('SELECT id FROM posts WHERE kind=? AND slug=?', $kind, $slug);
      if ($row) {
        $d->do_('DELETE FROM post_aliases WHERE post_id=?',   $row->{id});
        $d->do_('DELETE FROM post_revisions WHERE post_id=?', $row->{id});
      }
      $d->do_('DELETE FROM posts WHERE kind=? AND slug=?', $kind, $slug);
    }
  );
  $self->{render}->invalidate_post($kind, $slug);
  $self->{render}->invalidate_page($kind);
  $self->{render}->invalidate_home;
}

sub list_tags_recent {
  my ($self, $kind, $limit) = @_;
  $limit ||= 200;
  my $rows = $self->{db}->all(
    q{SELECT date, tags FROM posts
       WHERE kind=? AND tags<>''
       ORDER BY date DESC, created_at DESC, id DESC}, $kind
  );
  my (%first_date, %count, @order);
  for my $r (@$rows) {
    for my $t (split_tags($r->{tags})) {
      $count{$t}++;
      next if exists $first_date{$t};
      $first_date{$t} = $r->{date};
      push @order, $t;
    }
  }
  splice @order, $limit if @order > $limit;
  return [
    map +{tag => $_, last_used => $first_date{$_}, count => $count{$_}},
    @order
  ];
}

sub list_aliases {
  my ($self, $post_id) = @_;
  return $self->{db}->all(
    q{SELECT from_slug, created_at FROM post_aliases
        WHERE post_id=? ORDER BY created_at DESC}, $post_id
  );
}

sub list_revisions {
  my ($self, $post_id) = @_;
  return $self->{db}->all(
    q{SELECT revision_num, title, date, author, created_at, draft, publish_at
        FROM post_revisions
        WHERE post_id=?
        ORDER BY revision_num DESC}, $post_id
  );
}

sub get_revision {
  my ($self, $post_id, $rev) = @_;
  return $self->{db}->row(
    q{SELECT * FROM post_revisions WHERE post_id=? AND revision_num=?},
    $post_id, $rev
  );
}

sub delete_alias {
  my ($self, $kind, $from_slug) = @_;
  $self->{db}->do_(
    'DELETE FROM post_aliases WHERE kind=? AND from_slug=?',
    $kind, $from_slug
  );
  # Bust the alias path so the cached redirect goes away.
  $self->{render}->invalidate_route("/$kind/$from_slug/")
    if $self->{render};
}

# Word count of a markdown body. Strips code, inline links/images, HTML
# tags - keeps the visible text - then counts whitespace-separated words.
sub _word_count {
  my ($body) = @_;
  return 0 unless defined $body && length $body;
  my $t = $body;
  $t =~ s/```.*?```//gs;
  $t =~ s/`[^`\n]*`//g;
  $t =~ s/!?\[([^\]]*)\]\([^)]*\)/$1/g;
  $t =~ s/\[([^\]]*)\]\[[^\]]*\]/$1/g;
  $t =~ s/<[^>]+>//g;
  my @w = grep {length} split /\s+/, $t;
  return scalar @w;
}

# publish_at parser. Accepts undef/'' (immediate when not draft),
# integer epoch seconds, or 'YYYY-MM-DDTHH:MM[:SS]' interpreted as UTC.
sub normalize_publish_at {
  my ($v) = @_;
  return undef unless defined $v && length $v;
  if ($v =~ /^-?\d+$/) {
    return $v + 0;
  }
  if ($v =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?$/) {
    require Time::Local;
    my ($Y, $M, $D, $h, $m, $s) = ($1, $2, $3, $4, $5, $6 // 0);
    return eval {Time::Local::timegm($s, $m, $h, $D, $M - 1, $Y - 1900)};
  }
  return undef;
}

1;
