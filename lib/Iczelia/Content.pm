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

package Iczelia::Content;
use strict;
use warnings;
use Carp          qw(croak);
use Iczelia::Util qw(slugify);

# CRUD over pages, posts, updates, activity, webring, settings.
# Mutating methods invalidate caches via the injected $render.

sub new {
  my ($class, %arg) = @_;
  croak "db required"     unless $arg{db};
  croak "render required" unless $arg{render};
  return bless {db => $arg{db}, render => $arg{render}}, $class;
}

sub get_page {
  my ($self, $slug) = @_;
  return $self->{db}->row('SELECT * FROM pages WHERE slug=?', $slug);
}

sub save_page {
  my ($self, $slug, $title, $template, $data_json) = @_;
  $self->{db}->do_(
    q{
        UPDATE pages
           SET title=?, template=?, data=?, rendered_html=NULL,
               updated_at=strftime('%s','now')
         WHERE slug=?},
    $title, $template, $data_json, $slug
  );
  $self->{render}->invalidate_page($slug);
  $self->{render}->invalidate_home if $slug ne 'home';
}

sub get_post {
  my ($self, $kind, $slug) = @_;
  return $self->{db}
    ->row('SELECT * FROM posts WHERE kind=? AND slug=?', $kind, $slug);
}

sub list_posts {
  my ($self, $kind, %opt) = @_;
  my $sql = 'SELECT id, slug, title, date, tags, draft, updated_at
               FROM posts WHERE kind=?';
  $sql .= ' AND draft=0' if $opt{published_only};
  $sql .= ' ORDER BY date DESC, created_at DESC, id DESC';
  return $self->{db}->all($sql, $kind);
}

sub create_post {
  my ($self, $kind, $rec) = @_;
  my $base = $rec->{slug} || slugify($rec->{title}) || 'untitled-' . time;
  my $body = $rec->{body} // '';
  my $publish_at = _normalize_publish_at($rec->{publish_at});

  # INSERT OR IGNORE in a loop avoids the SELECT-then-INSERT race that
  # otherwise lets two concurrent creators both pass the uniqueness
  # check and collide on the UNIQUE(kind,slug) constraint.
  my $slug = $base;
  for (my $i = 2;; $i++) {
    my $rows = $self->{db}->do_(
      q{
            INSERT OR IGNORE INTO posts(kind, slug, title, date, tags, draft,
                              body, word_count, publish_at, created_at, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?,
                   strftime('%s','now'), strftime('%s','now'))},
      $kind,              $slug, $rec->{title}, $rec->{date},
      $rec->{tags} // '', $rec->{draft} ? 1 : 0,
      $body,              _word_count($body), $publish_at
    );
    last if $rows;
    $slug = "$base-$i";
    croak "create_post: cannot find a free slug" if $i > 1000;
  }
  $self->{render}->invalidate_post($kind, $slug);
  $self->{render}->invalidate_page($kind);
  $self->{render}->invalidate_home;
  return $slug;
}

sub update_post {
  my ($self, $kind, $old_slug, $rec) = @_;
  my $base       = $rec->{slug} || $old_slug;
  my $body       = $rec->{body} // '';
  my $publish_at = _normalize_publish_at($rec->{publish_at});

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
                   word_count=?, publish_at=?, rendered_html=NULL,
                   updated_at=strftime('%s','now')
             WHERE kind=? AND slug=?},
        $new_slug,             $rec->{title}, $rec->{date}, $rec->{tags} // '',
        $rec->{draft} ? 1 : 0, $body,
        _word_count($body),    $publish_at,
        $kind,                 $old_slug
      );
    }
  );
  if ($new_slug ne $old_slug) {
    $self->{render}->invalidate_post($kind, $old_slug);
  }
  $self->{render}->invalidate_post($kind, $new_slug);
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
  $self->{render}{cache}->bust("/$kind/$from_slug/")
    if $self->{render} && $self->{render}{cache};
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
sub _normalize_publish_at {
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

# Reserved-route policy for admin-defined dynamic pages.
#  - TREES: prefix off-limits, including any nested path.
#  - EXACT: only this exact path is taken; nested paths are still allowed.
#  - PREFIXES: any path that begins with this string.
my @RESERVED_TREES = (
  '/admin/',  '/blog/',  '/journal/', '/posts/',
  '/media/',  '/api/',   '/search/',  '/vendor/',
  '/assets-', '/fonts/', '/webring/', '/guestbook/',
  '/updates/',
);
my @RESERVED_EXACT = (
  '/about/',      '/cv/',        '/healthz',   '/login',
  '/logout',      '/feed.xml',   '/index.xml', '/rss.xml',
  '/sitemap.xml', '/robots.txt', '/pub.pgp',   '/favicon.ico',
);
my @RESERVED_PREFIXES = ('/cms.', '/style.', '/about.compat',);

sub validate_dynamic_route {
  my ($route) = @_;
  return (undef, 'route required')
    unless defined $route && length $route;
  return (undef, 'invalid route')
    unless $route =~ m{^/(?:[a-z0-9][a-z0-9-]*/){1,4}$};
  for my $p (@RESERVED_TREES) {
    return (undef, "reserved tree: $p")
      if index($route, $p) == 0;
  }
  for my $e (@RESERVED_EXACT) {
    return (undef, "reserved route: $e") if $route eq $e;
  }
  for my $p (@RESERVED_PREFIXES) {
    return (undef, "reserved prefix: $p")
      if index($route, $p) == 0;
  }
  return ($route, undef);
}

# Template name becomes a path component (views/<template>.tpl). Strict
# allowlist prevents traversal or injection.
sub _validate_template {
  my ($t) = @_;
  return 'generic' unless defined $t && length $t;
  return undef     unless $t =~ /^[a-z][a-z0-9_-]{0,40}$/;
  return $t;
}

sub list_dynamic_pages {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, route, title, template, updated_at
           FROM dynamic_pages ORDER BY route'
  );
}

sub get_dynamic_page {
  my ($self, $id) = @_;
  return $self->{db}->row('SELECT * FROM dynamic_pages WHERE id=?', $id);
}

sub get_dynamic_page_by_route {
  my ($self, $route) = @_;
  return $self->{db}->row('SELECT * FROM dynamic_pages WHERE route=?', $route);
}

sub create_dynamic_page {
  my ($self,  $rec) = @_;
  my ($route, $err) = validate_dynamic_route($rec->{route});
  return (undef, $err) if $err;
  return (undef, 'title required')
    unless defined $rec->{title} && length $rec->{title};
  my $tpl = _validate_template($rec->{template});
  return (undef, 'invalid template') unless defined $tpl;
  return (undef, 'route already exists')
    if $self->{db}->one('SELECT 1 FROM dynamic_pages WHERE route=?', $route);
  $self->{db}->do_(
    q{
        INSERT INTO dynamic_pages(route, title, template, data, updated_at)
        VALUES(?,?,?,?, strftime('%s','now'))},
    $route, $rec->{title}, $tpl, $rec->{data} // '{}'
  );
  if ($self->{render} && $self->{render}{cache}) {
    $self->{render}{cache}->bust_many($route, '/sitemap.xml');
  }
  return ($self->{db}->last_id, undef);
}

sub update_dynamic_page {
  my ($self, $id, $rec) = @_;
  my $cur = $self->get_dynamic_page($id)
    or return (undef, 'not found');
  my ($route, $err) =
    validate_dynamic_route($rec->{route} // $cur->{route});
  return (undef, $err) if $err;
  if ( $route ne $cur->{route}
    && $self->{db}
    ->one('SELECT 1 FROM dynamic_pages WHERE route=? AND id<>?', $route, $id))
  {
    return (undef, 'route already exists');
  }
  my $tpl = _validate_template($rec->{template} // $cur->{template});
  return (undef, 'invalid template') unless defined $tpl;
  $self->{db}->do_(
    q{
        UPDATE dynamic_pages
           SET route=?, title=?, template=?, data=?,
               rendered_html=NULL,
               updated_at=strftime('%s','now')
         WHERE id=?},
    $route, $rec->{title} // $cur->{title}, $tpl,
    $rec->{data} // $cur->{data}, $id
  );
  if ($self->{render} && $self->{render}{cache}) {
    $self->{render}{cache}->bust_many($cur->{route}, $route, '/sitemap.xml');
  }
  return ($id, undef);
}

sub delete_dynamic_page {
  my ($self, $id) = @_;
  my $cur = $self->get_dynamic_page($id) or return;
  $self->{db}->do_('DELETE FROM dynamic_pages WHERE id=?', $id);
  if ($self->{render} && $self->{render}{cache}) {
    $self->{render}{cache}->bust($cur->{route});
    $self->{render}{cache}->bust('/sitemap.xml');
  }
}

sub list_langs {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, name, aliases, updated_at, version
           FROM highlight_langs ORDER BY name'
  );
}

sub get_lang {
  my ($self, $id) = @_;
  return $self->{db}->row('SELECT * FROM highlight_langs WHERE id=?', $id);
}

sub _validate_lang_name {
  my ($n) = @_;
  return 0 unless defined $n && length $n;
  return $n =~ /^[a-z][a-z0-9+_:-]{0,40}$/ ? 1 : 0;
}

sub _validate_lang_record {
  my ($self, $rec, $cur_id) = @_;
  my $name = lc($rec->{name} // '');
  return (undef, 'name required') unless length $name;
  return (undef, 'name must be lowercase letters/digits/-_+:')
    unless _validate_lang_name($name);

  # Reject collisions against built-ins or other admin-defined langs.
  if (Iczelia::Highlight::known($name)) {
    my $row =
      $self->{db}->row('SELECT id FROM highlight_langs WHERE name=?', $name);
    if (!$row || ($cur_id && $row->{id} != $cur_id)) {
      return (undef, "name '$name' is reserved or in use");
    }
  }
  my @aliases;
  for my $a (split /[\s,]+/, ($rec->{aliases} // '')) {
    my $la = lc $a;
    next unless length $la;
    return (undef, "alias '$a' invalid")
      unless _validate_lang_name($la);
    next if $la eq $name;
    push @aliases, $la;
  }

  # Token strings are stored verbatim; Highlight::_build_db_rules
  # drops anything not matching [\w][\w:-]{0,63}, so junk is safe.
  my $lcm = $rec->{line_comment} // '';
  if (length $lcm
    && !($lcm =~ /^[[:punct:]]{1,3}$/ && $lcm =~ /^[\x21-\x7e]+$/))
  {
    return (undef, 'line_comment must be 1-3 ASCII punctuation chars');
  }
  my $bcm = $rec->{block_comment} // '';
  if (length $bcm && $bcm !~ /^\s*\S{1,3}\s+\S{1,3}\s*$/) {
    return (undef, 'block_comment must be "OPEN CLOSE"');
  }
  my $sq = $rec->{string_quotes} // '"';
  return (undef, 'string_quotes must be 1-4 chars')
    if length $sq < 1 || length $sq > 4;
  return (
    {
      name          => $name,
      aliases       => join(',', @aliases),
      keywords      => $rec->{keywords} // '',
      types         => $rec->{types}    // '',
      builtins      => $rec->{builtins} // '',
      line_comment  => $lcm,
      block_comment => $bcm,
      string_quotes => $sq,
    },
    undef
  );
}

sub create_lang {
  my ($self,  $rec) = @_;
  my ($clean, $err) = $self->_validate_lang_record($rec, undef);
  return (undef, $err) if $err;
  eval {
    $self->{db}->do_(
      q{
            INSERT INTO highlight_langs(
                name, aliases, keywords, types, builtins,
                line_comment, block_comment, string_quotes,
                updated_at, version)
            VALUES(?,?,?,?,?,?,?,?, strftime('%s','now'), 1)},
      $clean->{name},         $clean->{aliases}, $clean->{keywords},
      $clean->{types},        $clean->{builtins},
      $clean->{line_comment}, $clean->{block_comment},
      $clean->{string_quotes}
    );
    1;
  } or do {
    my $e = $@;
    return (undef, "insert failed: $e");
  };
  my $id = $self->{db}->last_id;
  $self->{render}->invalidate_all if $self->{render};
  return ($id, undef);
}

sub update_lang {
  my ($self, $id, $rec) = @_;
  my $cur = $self->get_lang($id) or return (undef, 'not found');
  my ($clean, $err) = $self->_validate_lang_record($rec, $id);
  return (undef, $err) if $err;
  $self->{db}->do_(
    q{
        UPDATE highlight_langs
           SET name=?, aliases=?, keywords=?, types=?, builtins=?,
               line_comment=?, block_comment=?, string_quotes=?,
               updated_at=strftime('%s','now'),
               version=version+1
         WHERE id=?},
    $clean->{name},          $clean->{aliases}, $clean->{keywords},
    $clean->{types},         $clean->{builtins},
    $clean->{line_comment},  $clean->{block_comment},
    $clean->{string_quotes}, $id
  );
  $self->{render}->invalidate_all if $self->{render};
  return ($id, undef);
}

sub delete_lang {
  my ($self, $id) = @_;
  $self->{db}->do_('DELETE FROM highlight_langs WHERE id=?', $id);
  $self->{render}->invalidate_all if $self->{render};
}

sub list_updates {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, date, body, position FROM updates
         ORDER BY date DESC, position DESC, id DESC'
  );
}

sub replace_updates {
  my ($self, $rows) = @_;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM updates');
      my $pos = scalar @$rows;
      for my $r (@$rows) {
        next unless ($r->{date} // '') =~ /^\d{4}-\d{2}-\d{2}$/;
        $d->do_('INSERT INTO updates(date, body, position) VALUES(?,?,?)',
          $r->{date}, ($r->{body} // ''), $pos--);
      }
    }
  );
  $self->{render}->invalidate_home;
  $self->{render}->invalidate_page('updates');
}

sub set_currently {
  my ($self, $text) = @_;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_("DELETE FROM activity WHERE source='currently'");
      $d->do_(
        q{INSERT INTO activity(source, text, position, fetched_at)
                  VALUES('currently', ?, 0, strftime('%s','now'))}, $text
      ) if defined $text && length $text;
    }
  );
  $self->{render}->invalidate_home;
}

sub list_webring {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, position, section, name, url, image_url
         FROM webring_members ORDER BY position'
  );
}

my %WEBRING_SECTIONS = map {$_ => 1} qw(own others more);

sub replace_webring {
  my ($self, $rows) = @_;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM webring_members');
      my $pos = 0;
      for my $r (@$rows) {
        my $name    = $r->{name}      // '';
        my $url     = $r->{url}       // '';
        my $img     = $r->{image_url} // '';
        my $section = $r->{section}   // 'others';
        $section = 'others' unless $WEBRING_SECTIONS{$section};
        next      unless length $name;
        $url = '' unless $url =~ m{^https?://}i;
        next      unless length $url || length $img;
        $img = ''
          unless $img =~ m{^/(?:media|assets-)} || $img =~ m{^https?://}i;
        $d->do_(
          'INSERT INTO webring_members(position, section, name, url, image_url)
                 VALUES(?,?,?,?,?)',
          $pos++, $section, $name, $url,
          length $img ? $img : undef
        );
      }
    }
  );
  $self->{render}->invalidate_page('webring');
}

sub all_settings {
  my ($self) = @_;
  my $rows = $self->{db}->all('SELECT key, value FROM settings ORDER BY key');
  my %h;
  $h{$_->{key}} = $_->{value} for @$rows;
  return \%h;
}

sub set_settings {
  my ($self, $kv) = @_;
  my $math_changed = grep {/^math\./} keys %$kv;

  $self->{db}->tx(
    sub {
      my $d = shift;
      for my $k (keys %$kv) {
        $d->do_(
          q{INSERT INTO settings(key, value) VALUES(?,?)
                      ON CONFLICT(key) DO UPDATE SET value=excluded.value},
          $k, $kv->{$k} // ''
        );
      }
    }
  );

  # Settings touch every page; wipe response_cache and per-row
  # rendered_html. The tex_cache DELETE is hygiene (the key already
  # encodes math params).
  $self->{render}->invalidate_all;
  $self->{db}->do_('UPDATE pages SET rendered_html = NULL');
  $self->{db}->do_('UPDATE posts SET rendered_html = NULL');
  if ($math_changed) {
    $self->{db}->do_('DELETE FROM tex_cache');
  }
}

sub list_activity {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT * FROM activity ORDER BY source, position'
  );
}

sub list_media {
  my ($self, $limit) = @_;
  $limit //= 200;
  return $self->{db}->all(
    q{SELECT id, filename, orig_name, content_type, size, sha256,
             uploaded_at, thumb_filename
        FROM media ORDER BY uploaded_at DESC LIMIT ?}, $limit
  );
}

sub get_media {
  my ($self, $id) = @_;
  return $self->{db}->row(
    'SELECT filename, thumb_filename FROM media WHERE id=?', $id
  );
}

sub create_media {
  my ($self, %m) = @_;
  $self->{db}->do_(
    q{INSERT OR IGNORE INTO media
        (filename, orig_name, content_type, size, sha256,
         uploaded_at, thumb_filename)
        VALUES(?, ?, ?, ?, ?, strftime('%s','now'), ?)},
    @m{qw(filename orig_name content_type size sha256 thumb_filename)}
  );
}

sub delete_media {
  my ($self, $id) = @_;
  $self->{db}->do_('DELETE FROM media WHERE id=?', $id);
}

1;
