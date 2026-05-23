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

package Iczelia::Subpages;
use strict;
use warnings;
use DBI                   ();
use IO::Uncompress::Unzip ();

# Static subpages: admin-uploaded HTML/CSS/JS bundles served under
# /<slug>/. Bundle files live in the subpage_files table; binary
# content is bound SQL_BLOB so sqlite_unicode can't re-encode it.

use constant {
  MAX_FILES => 1000,
  MAX_FILE  => 8 * 1024 * 1024,
  MAX_TOTAL => 32 * 1024 * 1024,
};

my %CT = (
  html => 'text/html; charset=utf-8',
  htm  => 'text/html; charset=utf-8',
  css  => 'text/css; charset=utf-8',
  js   => 'application/javascript; charset=utf-8',
  mjs  => 'application/javascript; charset=utf-8',
  json => 'application/json',
  xml  => 'application/xml',
  svg  => 'image/svg+xml',
  txt  => 'text/plain; charset=utf-8',
  md   => 'text/markdown; charset=utf-8',
  csv  => 'text/csv; charset=utf-8',
  png  => 'image/png',
  jpg  => 'image/jpeg',
  jpeg => 'image/jpeg',
  gif  => 'image/gif',
  webp => 'image/webp',
  avif => 'image/avif',
  ico  => 'image/x-icon',
  bmp  => 'image/bmp',
  woff => 'font/woff',
  woff2 => 'font/woff2',
  ttf  => 'font/ttf',
  otf  => 'font/otf',
  eot  => 'application/vnd.ms-fontobject',
  mp4  => 'video/mp4',
  webm => 'video/webm',
  mp3  => 'audio/mpeg',
  ogg  => 'audio/ogg',
  wav  => 'audio/wav',
  pdf  => 'application/pdf',
  wasm => 'application/wasm',
);

# Top-level path segments a subpage slug must not shadow.
my %RESERVED = map {$_ => 1} qw(
  admin api blog journal series media vendor fonts webring guestbook
  updates search about cv posts healthz favicon robots sitemap feed
  cms pub static assets css js img images
);

sub valid_slug {
  my ($slug) = @_;
  return 0 unless defined $slug && $slug =~ /^[a-z0-9][a-z0-9-]{0,62}$/;
  return 0 if $slug =~ /^assets-/;
  return 0 if $RESERVED{$slug};
  return 1;
}

sub content_type_for {
  my ($path) = @_;
  my ($ext) = (defined $path ? $path : '') =~ /\.([A-Za-z0-9]+)\z/;
  return 'application/octet-stream' unless defined $ext;
  return $CT{lc $ext} || 'application/octet-stream';
}

sub is_text_type {
  my ($ct) = @_;
  return 0 unless defined $ct;
  return 1 if $ct =~ m{^text/};
  return 1 if $ct =~ m{^application/(?:javascript|json|xml)\b};
  return 1 if $ct =~ m{^image/svg\+xml};
  return 0;
}

# A bundle-relative path with traversal, absolute prefixes and control
# characters rejected. Returns the cleaned path or undef.
sub sanitize_rel_path {
  my ($path) = @_;
  return undef unless defined $path;
  $path =~ s{\\}{/}g;
  return undef if $path =~ /\0/;
  return undef if $path =~ /^[A-Za-z]:/;
  my @out;
  for my $seg (split m{/}, $path, -1) {
    next if $seg eq '' || $seg eq '.';
    return undef if $seg eq '..';
    return undef if $seg =~ /[\x00-\x1f]/;
    push @out, $seg;
  }
  my $rel = join '/', @out;
  return undef unless length $rel && length($rel) <= 255;
  return $rel;
}

sub _is_binary {
  my ($content, $ct) = @_;
  return 1 if index($content, "\0") >= 0;
  return is_text_type($ct) ? 0 : 1;
}

# Drop a single shared top-level directory (the common "everything is
# inside mysite/" zip layout) so index.html lands at the bundle root.
sub _strip_common_prefix {
  my (@raw) = @_;
  for (1 .. 8) {
    my %first;
    for my $r (@raw) {
      if ($r->[0] =~ m{^([^/]+)/.}) {$first{$1} = 1}
      else {return @raw}
    }
    last unless keys(%first) == 1;
    my ($pfx) = keys %first;
    $_->[0] =~ s{^\Q$pfx\E/}{} for @raw;
  }
  return @raw;
}

# extract_zip($bytes, %opt) -> (\@files, undef) | (undef, $error).
# Each file: { path, content, content_type, size, is_binary }.
# unlimited => 1 drops the file/total/count caps (filesystem imports).
sub extract_zip {
  my ($data, %opt) = @_;
  my $unlimited = $opt{unlimited};
  return (undef, 'empty upload') unless defined $data && length $data;

  my $z = IO::Uncompress::Unzip->new(\$data, Transparent => 0)
    or return (undef, 'not a valid zip file');

  my @raw;
  my $total  = 0;
  my $status = 1;
  for (; $status > 0; $status = $z->nextStream) {
    my $name = eval {$z->getHeaderInfo->{Name}};
    $name = '' unless defined $name;
    next if $name eq '' || $name =~ m{/\z};
    next if $name =~ m{(?:^|/)__MACOSX(?:/|\z)};
    next if $name =~ m{(?:^|/)\.DS_Store\z};
    next if $name =~ m{(?:^|/)Thumbs\.db\z}i;

    my $content = '';
    my $buf;
    my $n;
    while (($n = $z->read($buf)) > 0) {
      $content .= $buf;
      return (undef, "file too large: $name")
        if !$unlimited && length($content) > MAX_FILE;
    }
    return (undef, 'corrupt zip data') if $n < 0;

    $total += length $content;
    return (undef, 'bundle too large')
      if !$unlimited && $total > MAX_TOTAL;
    push @raw, [$name, $content];
    return (undef, 'too many files in bundle')
      if !$unlimited && @raw > MAX_FILES;
  }
  return (undef, 'corrupt zip file') if $status < 0;
  return (undef, 'zip contains no files') unless @raw;

  @raw = _strip_common_prefix(@raw);

  my (@files, %seen);
  for my $r (@raw) {
    my $rel = sanitize_rel_path($r->[0]);
    next unless defined $rel;
    next if $seen{$rel}++;
    my $ct = content_type_for($rel);
    push @files,
      {
      path         => $rel,
      content      => $r->[1],
      content_type => $ct,
      size         => length($r->[1]),
      is_binary    => _is_binary($r->[1], $ct),
      };
  }
  return (undef, 'zip contains no usable files') unless @files;
  return (\@files, undef);
}

sub list {
  my ($db) = @_;
  return $db->all(
    q{SELECT s.*,
             (SELECT COUNT(*) FROM subpage_files f
               WHERE f.subpage_id = s.id) AS file_count
        FROM subpages s ORDER BY s.slug}
  );
}

sub get        {$_[0]->row('SELECT * FROM subpages WHERE id=?',   $_[1])}
sub get_by_slug {$_[0]->row('SELECT * FROM subpages WHERE slug=?', $_[1])}

sub files {
  my ($db, $id) = @_;
  return $db->all(
    q{SELECT id, path, content_type, size, is_binary, updated_at
        FROM subpage_files WHERE subpage_id=? ORDER BY path}, $id
  );
}

sub file {
  my ($db, $id, $path) = @_;
  return $db->row(
    q{SELECT * FROM subpage_files WHERE subpage_id=? AND path=?},
    $id, $path
  );
}

sub file_count {
  my ($db, $id) = @_;
  return $db->one('SELECT COUNT(*) FROM subpage_files WHERE subpage_id=?',
    $id) // 0;
}

sub _insert_file {
  my ($d, $id, $f, $now) = @_;
  my $sth = $d->dbh->prepare(
    q{INSERT INTO subpage_files
        (subpage_id, path, content, content_type, size, is_binary, updated_at)
        VALUES(?,?,?,?,?,?,?)}
  );
  $sth->bind_param(1, $id);
  $sth->bind_param(2, $f->{path});
  $sth->bind_param(3, $f->{content}, DBI::SQL_BLOB());
  $sth->bind_param(4, $f->{content_type});
  $sth->bind_param(5, $f->{size});
  $sth->bind_param(6, $f->{is_binary} ? 1 : 0);
  $sth->bind_param(7, $now);
  $sth->execute;
}

sub create {
  my ($db, $slug, $title, $files) = @_;
  my $now = time;
  my $id;
  $db->tx(
    sub {
      my $d = shift;
      $d->do_(
        q{INSERT INTO subpages(slug, title, created_at, updated_at)
            VALUES(?,?,?,?)}, $slug, (defined $title ? $title : ''),
        $now, $now
      );
      $id = $d->last_id;
      _insert_file($d, $id, $_, $now) for @$files;
    }
  );
  return $id;
}

sub replace_files {
  my ($db, $id, $files) = @_;
  my $now = time;
  $db->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM subpage_files WHERE subpage_id=?', $id);
      _insert_file($d, $id, $_, $now) for @$files;
      $d->do_('UPDATE subpages SET updated_at=? WHERE id=?', $now, $id);
    }
  );
}

# Upsert a single bundle file. Returns the cleaned path or undef.
sub put_file {
  my ($db, $id, $path, $content, %opt) = @_;
  my $rel = sanitize_rel_path($path);
  return undef unless defined $rel;
  $content = '' unless defined $content;
  my $ct = $opt{content_type} || content_type_for($rel);
  my $bin =
      exists $opt{is_binary}
    ? ($opt{is_binary} ? 1 : 0)
    : _is_binary($content, $ct);
  my $now = time;
  $db->tx(
    sub {
      my $d   = shift;
      my $sth = $d->dbh->prepare(
        q{INSERT INTO subpage_files
            (subpage_id, path, content, content_type, size, is_binary,
             updated_at)
            VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(subpage_id, path) DO UPDATE SET
              content=excluded.content, content_type=excluded.content_type,
              size=excluded.size, is_binary=excluded.is_binary,
              updated_at=excluded.updated_at}
      );
      $sth->bind_param(1, $id);
      $sth->bind_param(2, $rel);
      $sth->bind_param(3, $content, DBI::SQL_BLOB());
      $sth->bind_param(4, $ct);
      $sth->bind_param(5, length $content);
      $sth->bind_param(6, $bin);
      $sth->bind_param(7, $now);
      $sth->execute;
      $d->do_('UPDATE subpages SET updated_at=? WHERE id=?', $now, $id);
    }
  );
  return $rel;
}

sub delete_file {
  my ($db, $id, $path) = @_;
  my $n = $db->do_(
    'DELETE FROM subpage_files WHERE subpage_id=? AND path=?', $id, $path);
  $db->do_('UPDATE subpages SET updated_at=? WHERE id=?', time, $id)
    if $n;
  return $n;
}

sub update_meta {
  my ($db, $id, $slug, $title, $listing) = @_;
  $db->do_(
    'UPDATE subpages SET slug=?, title=?, listing=?, updated_at=? WHERE id=?',
    $slug, (defined $title ? $title : ''),
    ($listing ? 1 : 0), time, $id
  );
}

# Immediate children of $dir (relative to the bundle root). Returns an
# arrayref of { type => 'dir'|'file', name, updated_at, size? } with
# directories first, both groups alphabetical. $dir may be '' (root),
# 'css', 'css/sub', etc.
sub directory_entries {
  my ($db, $id, $dir) = @_;
  $dir = '' unless defined $dir;
  $dir =~ s{^/+}{};
  $dir =~ s{/+$}{};
  my $prefix = length($dir) ? "$dir/" : '';
  my $rows = $db->all(
    q{SELECT path, size, updated_at FROM subpage_files
        WHERE subpage_id=? ORDER BY path}, $id
  );
  my (%dirs, @files);
  for my $r (@$rows) {
    next unless index($r->{path}, $prefix) == 0;
    my $rest = substr($r->{path}, length $prefix);
    next if $rest eq '';
    if ($rest =~ m{^([^/]+)/}) {
      my $name = $1;
      $dirs{$name} = $r->{updated_at}
        if !exists $dirs{$name} || $r->{updated_at} > $dirs{$name};
    }
    else {
      push @files,
        {
        type       => 'file',
        name       => $rest,
        size       => $r->{size},
        updated_at => $r->{updated_at},
        path       => $r->{path},
        };
    }
  }
  my @out = map { {type => 'dir', name => $_, updated_at => $dirs{$_}} }
    sort keys %dirs;
  push @out, sort { $a->{name} cmp $b->{name} } @files;
  return \@out;
}

sub delete {
  my ($db, $id) = @_;
  $db->do_('DELETE FROM subpages WHERE id=?', $id);
}

1;
