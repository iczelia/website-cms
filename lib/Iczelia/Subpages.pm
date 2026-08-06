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
use Encode                ();
use IO::Uncompress::Unzip ();
use Iczelia::Highlight    ();

# Static subpages: admin-uploaded HTML/CSS/JS bundles served under
# /<slug>/. Bundle files live in the subpage_files table; binary
# content is bound SQL_BLOB so sqlite_unicode can't re-encode it.

use constant {
  MAX_FILES => 1000,
  MAX_FILE  => 8 * 1024 * 1024,
  MAX_TOTAL => 32 * 1024 * 1024,

  # Cap on a single blob read during a listing. Past it, language
  # detection uses the name only and a README is not rendered.
  SNIFF_MAX_SIZE => 1024 * 1024,
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
  cms pub static assets css js img images git
);

sub valid_slug {
  my ($slug) = @_;
  return 0 unless defined $slug && $slug =~ /^[a-z0-9][a-z0-9-]{0,62}$/;
  return 0 if $slug =~ /^assets-/;
  return 0 if $RESERVED{$slug};
  return 1;
}

# Icon mapping shared by the public directory index and the admin
# panel's directory view.
my %EXT_ICON = (
  html  => 'html.png',     htm   => 'html.png',  xhtml => 'html.png',
  css   => 'css.png',      scss  => 'css.png',   sass  => 'css.png',
  less  => 'css.png',
  xml   => 'xml.png',      json  => 'xml.png',
  yaml  => 'xml.png',      yml   => 'xml.png',  toml => 'xml.png',
  txt   => 'text.png',     md    => 'text.png', markdown => 'text.png',
  rst   => 'text.png',     log   => 'text.png', csv => 'text.png',
  tsv   => 'text.png',     ini   => 'text.png', cfg => 'text.png',
  conf  => 'text.png',
  js    => 'code.png',     mjs   => 'code.png',  cjs => 'code.png',
  ts    => 'code.png',     tsx   => 'code.png',  jsx => 'code.png',
  rb    => 'code.png',     go    => 'code.png',  rs  => 'code.png',
  c     => 'code.png',     h     => 'code.png',
  cc    => 'code.png',     cpp   => 'code.png',  hpp => 'code.png',
  cxx   => 'code.png',     hxx   => 'code.png',
  cs    => 'code.png',     kt    => 'code.png',  scala => 'code.png',
  swift => 'code.png',     lua   => 'code.png',  dart => 'code.png',
  r     => 'code.png',     jl    => 'code.png',  ex => 'code.png',
  exs   => 'code.png',     erl   => 'code.png',  clj => 'code.png',
  cljs  => 'code.png',     lisp  => 'code.png',  el  => 'code.png',
  py    => 'python.png',   pyw   => 'python.png', pyc => 'python.png',
  pyi   => 'python.png',
  pl    => 'perl.png',     pm    => 'perl.png',  t   => 'perl.png',
  php   => 'php.png',      phtml => 'php.png',   php5 => 'php.png',
  java  => 'java.png',     class => 'java.png',
  hs    => 'haskell.png',
  lhs   => 'lhaskell.png',
  scm   => 'scheme.png',   ss    => 'scheme.png', rkt => 'scheme.png',
  sh    => 'shell.png',    bash  => 'shell.png',  zsh => 'shell.png',
  ksh   => 'shell.png',    fish  => 'shell.png',  csh => 'shell.png',
  tex   => 'tex.png',      sty   => 'tex.png',    cls => 'tex.png',
  ltx   => 'tex.png',      bib   => 'tex.png',
  dvi   => 'dvi.png',
  sql   => 'sql.png',
  patch => 'patch.png',    diff  => 'patch.png',
  doc   => 'word.png',     docx  => 'word.png',
  xls   => 'excel.png',    xlsx  => 'excel.png',
  ppt   => 'powerpoint.png', pptx => 'powerpoint.png',
  odt   => 'odt.png',
  ods   => 'ods.png',
  odp   => 'odp.png',
  rtf   => 'rtf.png',
  png   => 'image.png',    jpg   => 'image.png',  jpeg  => 'image.png',
  gif   => 'image.png',    webp  => 'image.png',  avif  => 'image.png',
  bmp   => 'image.png',    ico   => 'image.png',  svg   => 'image.png',
  tiff  => 'image.png',    tif   => 'image.png',  jp2   => 'image.png',
  heic  => 'image.png',    heif  => 'image.png',
  xpm   => 'image.png',    xbm   => 'image.png',
  ppm   => 'image.png',    pbm   => 'image.png',  pgm   => 'image.png',
  pnm   => 'image.png',    tga   => 'image.png',
  psd   => 'psd.png',
  xcf   => 'xcf.png',
  '3ds' => '3d.png',       obj   => '3d.png',    stl   => '3d.png',
  fbx   => '3d.png',       dae   => '3d.png',    ply   => '3d.png',
  blend => 'blender.png',
  mp3   => 'audio.png',    wav   => 'audio.png',  ogg   => 'audio.png',
  flac  => 'audio.png',    m4a   => 'audio.png',  oga   => 'audio.png',
  opus  => 'audio.png',    aac   => 'audio.png',  ape   => 'audio.png',
  wma   => 'audio.png',    aiff  => 'audio.png',  aif   => 'audio.png',
  au    => 'audio.png',
  mid   => 'midi.png',     midi  => 'midi.png',
  mod   => 'tracker.png',  it    => 'tracker.png', s3m  => 'tracker.png',
  xm    => 'tracker.png',  stm   => 'tracker.png',
  mp4   => 'video.png',    webm  => 'video.png',  mov   => 'video.png',
  mkv   => 'video.png',    avi   => 'video.png',  ogv   => 'video.png',
  wmv   => 'video.png',    flv   => 'video.png',  m4v   => 'video.png',
  mpg   => 'video.png',    mpeg  => 'video.png',  '3gp' => 'video.png',
  zip   => 'archive.png',  tar   => 'archive.png', gz   => 'archive.png',
  tgz   => 'archive.png',  bz2   => 'archive.png', xz   => 'archive.png',
  tbz   => 'archive.png',  tbz2  => 'archive.png', txz  => 'archive.png',
  '7z'  => 'archive.png',  rar   => 'archive.png', br   => 'archive.png',
  zst   => 'archive.png',  lz    => 'archive.png', lzma => 'archive.png',
  lha   => 'archive.png',  lzh   => 'archive.png', arj  => 'archive.png',
  cab   => 'archive.png',  cpio  => 'archive.png',
  deb   => 'deb.png',
  rpm   => 'rpm.png',
  jar   => 'jar.png',      war   => 'jar.png',    ear  => 'jar.png',
  iso   => 'iso.png',      img   => 'iso.png',    dmg  => 'iso.png',
  pdf   => 'pdf.png',
  ps    => 'ps.png',       eps   => 'ps.png',
  ttf   => 'font.png',     otf   => 'font.png',
  woff  => 'font.png',     woff2 => 'font.png',  eot => 'font.png',
  pfa   => 'font.png',     pfb   => 'font.png',  bdf => 'font.png',
  pcf   => 'font.png',
  exe   => 'exec.png',     bin   => 'exec.png',   so   => 'exec.png',
  dll   => 'exec.png',     wasm  => 'exec.png',   dylib => 'exec.png',
  msi   => 'exec.png',     appimage => 'exec.png',
  o     => 'object.png',   a     => 'object.png',
  lib   => 'object.png',
  swf   => 'flash.png',
  vcf   => 'vcard.png',
  ics   => 'calendar.png', vcs   => 'calendar.png',
  pgp   => 'pgp.png',      gpg   => 'pgp.png',    asc => 'pgp.png',
  sig   => 'pgp.png',
  dia   => 'dia.png',
  '1'   => 'man.png',      '2'   => 'man.png',    '3'   => 'man.png',
  '4'   => 'man.png',      '5'   => 'man.png',    '6'   => 'man.png',
  '7'   => 'man.png',      '8'   => 'man.png',    man  => 'man.png',
);

my %NAME_ICON = (
  'readme'      => 'readme.png',
  'readme.md'   => 'readme.png',
  'readme.txt'  => 'readme.png',
  'readme.rst'  => 'readme.png',
  'readme.markdown' => 'readme.png',
  'license'     => 'readme.png',
  'license.txt' => 'readme.png',
  'license.md'  => 'readme.png',
  'copying'     => 'readme.png',
  'authors'     => 'readme.png',
  'changelog'   => 'readme.png',
  'makefile'    => 'makefile.png',
  'gnumakefile' => 'makefile.png',
);

sub icon_for {
  my ($name) = @_;
  return 'file.png' unless defined $name && length $name;
  my $lc = lc $name;
  return $NAME_ICON{$lc} if exists $NAME_ICON{$lc};
  my ($ext) = $lc =~ /\.([a-z0-9]+)\z/;
  return 'file.png' unless defined $ext;
  return $EXT_ICON{$ext} || 'file.png';
}

# icon_for_entry's name/content-type half; undef when the choice needs
# {lang}. _attach_langs keys its sniff off this.
sub icon_from_type {
  my ($name, %meta) = @_;
  return 'folder.png' if ($meta{type} // '') eq 'dir';
  return 'file.png' unless defined $name && length $name;
  return icon_for($name) if is_readme_name($name);

  my $ct = $meta{content_type} // '';
  return 'image.png'   if $ct =~ m{\Aimage/};
  return 'audio.png'   if $ct =~ m{\Aaudio/};
  return 'video.png'   if $ct =~ m{\Avideo/};
  return 'pdf.png'     if $ct =~ m{\Aapplication/pdf\b};
  return 'archive.png' if $ct =~ m{\Aapplication/(?:zip|gzip|x-bzip2|x-xz|x-7z-compressed|x-rar|x-tar)\b};
  return 'font.png'    if $ct =~ m{\A(?:font/|application/(?:font|vnd\.ms-fontobject))};
  return 'exec.png'    if $ct =~ m{\Aapplication/(?:wasm|x-elf)\b};
  return 'file.png'    if $meta{is_binary};
  return undef;
}

sub icon_for_entry {
  my ($name, %meta) = @_;
  my $early = icon_from_type($name, %meta);
  return $early if defined $early;

  my $ct   = $meta{content_type} // '';
  my $lang = $meta{lang};
  if (defined $lang && length $lang) {
    return 'lhaskell.png' if $lang eq 'haskell' && $name =~ /\.lhs\z/i;
    return 'python.png'   if $lang eq 'python';
    return 'perl.png'     if $lang eq 'perl';
    return 'php.png'      if $lang eq 'php';
    return 'java.png'     if $lang eq 'java';
    return 'haskell.png'  if $lang eq 'haskell';
    return 'scheme.png'   if $lang eq 'lisp';
    return 'shell.png'    if $lang eq 'bash';
    return 'sql.png'      if $lang eq 'sql';
    return 'css.png'      if $lang eq 'css';
    return 'xml.png'      if $lang eq 'html' && $ct =~ m{\Aapplication/xml\b};
    return 'image.png'    if $lang eq 'html' && $ct =~ m{\Aimage/svg\+xml\b};
    return 'html.png'     if $lang eq 'html';
    return 'xml.png'      if $lang =~ /\A(?:json|yaml|toml)\z/;
    return 'makefile.png' if $lang eq 'make';
    return 'patch.png'    if $lang eq 'diff';
    return 'text.png'     if $lang eq 'markdown';
    return 'code.png';
  }

  return 'text.png'    if is_text_type($ct);
  return icon_for($name);
}

sub fmt_size {
  my ($n) = @_;
  return '-' unless defined $n;
  return "$n B"                          if $n < 1024;
  return sprintf('%.1f KB', $n / 1024)   if $n < 1024 * 1024;
  return sprintf('%.1f MB', $n / 1048576) if $n < 1073741824;
  return sprintf('%.1f GB', $n / 1073741824);
}

sub fmt_mtime {
  my ($ts) = @_;
  return '-' unless $ts;
  my @t = gmtime($ts);
  return sprintf '%04d-%02d-%02d %02d:%02d',
    $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1];
}

# Is this entry name a README we should render above a listing? Returns
# the base bareword ("readme") if so, else undef. Accepts an optional
# extension from a small whitelist.
sub is_readme_name {
  my ($name) = @_;
  return 0 unless defined $name;
  return $name =~ /\A(?:readme)(?:\.(?:md|txt|rst|markdown))?\z/i ? 1 : 0;
}

sub content_type_for {
  my ($path) = @_;
  my ($ext) = (defined $path ? $path : '') =~ /\.([A-Za-z0-9]+)\z/;
  return 'application/octet-stream' unless defined $ext;
  return $CT{lc $ext} || 'application/octet-stream';
}

sub detect_file_type {
  my ($path, $content) = @_;
  my $ct = content_type_for($path);
  my $binary;
  if (defined $content) {
    my $magic = _magic_type($content);
    $ct = _prefer_magic_type($path, $ct, $magic) if defined $magic;
    $binary = _content_looks_binary($content, $ct) ? 1 : 0;
    if ($ct eq 'application/octet-stream' && !$binary) {
      $ct = 'text/plain; charset=utf-8';
    }
  }
  else {
    $binary = is_text_type($ct) ? 0 : 1;
  }
  my $lang = $binary ? undef : Iczelia::Highlight::lang_for_file($path, $content);
  return {
    content_type => $ct,
    is_binary    => $binary,
    lang         => $lang,
    icon         => icon_for_entry($path,
      content_type => $ct, is_binary => $binary, lang => $lang),
  };
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
  return _content_looks_binary($content, $ct);
}

sub _content_looks_binary {
  my ($content, $ct) = @_;
  return 1 if defined $content && index($content, "\0") >= 0;
  return 0 if is_text_type($ct);
  return 0 unless defined $content && length $content;
  my $sample = substr($content, 0, 8192);
  return 0 if eval { Encode::decode('UTF-8', $sample, Encode::FB_CROAK()); 1 };
  my $ctrl = () = $sample =~ /[\x00-\x08\x0B\x0C\x0E-\x1F]/g;
  return ($ctrl / (length($sample) || 1)) > 0.02 ? 1 : 0;
}

sub _magic_type {
  my ($c) = @_;
  return undef unless defined $c && length $c;
  return 'image/png'              if $c =~ /\A\x89PNG\r\n\x1a\n/s;
  return 'image/jpeg'             if $c =~ /\A\xff\xd8\xff/s;
  return 'image/gif'              if $c =~ /\AGIF8[79]a/s;
  return 'image/webp'             if $c =~ /\ARIFF....WEBP/s;
  return 'image/bmp'              if $c =~ /\ABM/s;
  return 'image/x-icon'           if $c =~ /\A\x00\x00\x01\x00/s;
  return 'image/tiff'             if $c =~ /\A(?:II\*\x00|MM\x00\*)/s;
  return 'application/pdf'        if $c =~ /\A%PDF-/s;
  return 'application/zip'        if $c =~ /\APK\x03\x04/s;
  return 'application/gzip'       if $c =~ /\A\x1f\x8b/s;
  return 'application/x-bzip2'    if $c =~ /\ABZh/s;
  return 'application/x-xz'       if $c =~ /\A\xfd7zXZ\x00/s;
  return 'application/x-7z-compressed' if $c =~ /\A7z\xbc\xaf\x27\x1c/s;
  return 'application/x-rar'      if $c =~ /\ARar!\x1a\x07/s;
  return 'application/x-tar'      if length($c) > 265 && substr($c, 257, 5) eq 'ustar';
  return 'application/wasm'       if $c =~ /\A\x00asm/s;
  return 'application/x-elf'      if $c =~ /\A\x7fELF/s;
  return 'application/vnd.sqlite3' if $c =~ /\ASQLite format 3\x00/s;
  return 'audio/ogg'              if $c =~ /\AOggS/s;
  return 'audio/mpeg'             if $c =~ /\A(?:ID3|\xff[\xfb\xf3\xf2])/s;
  return 'application/xml'        if $c =~ /\A(?:\xEF\xBB\xBF)?\s*<\?xml\b/is;
  return 'text/html; charset=utf-8'
    if $c =~ /\A(?:\xEF\xBB\xBF)?\s*(?:<!doctype\s+html\b|<html\b)/is;
  return undef;
}

sub _prefer_magic_type {
  my ($path, $by_ext, $magic) = @_;
  return $by_ext unless defined $magic && length $magic;
  return $magic if !defined $by_ext || $by_ext eq 'application/octet-stream';
  return $magic if $magic =~ m{\A(?:image|audio|video|font)/};
  return $magic if $magic =~ m{\Aapplication/(?:pdf|zip|gzip|x-|wasm|vnd\.sqlite3)};
  return $by_ext;
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
    my $type = detect_file_type($rel, $r->[1]);
    push @files,
      {
      path         => $rel,
      content      => $r->[1],
      content_type => $type->{content_type},
      size         => length($r->[1]),
      is_binary    => $type->{is_binary},
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
  my ($paths) = put_files(
    $db, $id,
    [
      {
        path    => $path,
        content => $content,
        (defined $opt{content_type}
          ? (content_type => $opt{content_type}) : ()),
        (exists $opt{is_binary}
          ? (is_binary => $opt{is_binary}) : ()),
      }
    ],
    # put_file historically had no size cap; its callers enforce the
    # appropriate limit themselves (or import trusted bundle content).
    unlimited => 1,
  );
  return $paths ? $paths->[0] : undef;
}

# Atomically upsert a batch of files. Validation and type detection happen
# before the transaction, so a bad path, duplicate destination or oversized
# native upload cannot leave half a directory behind.
#
# Returns (\@clean_paths, undef) on success, or (undef, $error).
sub put_files {
  my ($db, $id, $files, %opt) = @_;
  return (undef, 'choose one or more files')
    unless ref($files) eq 'ARRAY' && @$files;

  my (@ready, %seen);
  for my $f (@$files) {
    my $rel = sanitize_rel_path($f->{path});
    return (undef, 'invalid file path') unless defined $rel;
    return (undef, "duplicate upload path: $rel") if $seen{$rel}++;

    my $content = defined $f->{content} ? $f->{content} : '';
    return (undef, "file too large: $rel")
      if !$opt{unlimited} && length($content) > MAX_FILE;

    my $det = detect_file_type($rel, $content);
    my $ct = defined $f->{content_type} && length $f->{content_type}
      ? $f->{content_type} : $det->{content_type};
    my $bin = exists $f->{is_binary}
      ? ($f->{is_binary} ? 1 : 0)
      : _is_binary($content, $ct);
    push @ready, {
      path         => $rel,
      content      => $content,
      content_type => $ct,
      size         => length($content),
      is_binary    => $bin,
    };
  }

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
      for my $f (@ready) {
        $sth->bind_param(1, $id);
        $sth->bind_param(2, $f->{path});
        $sth->bind_param(3, $f->{content}, DBI::SQL_BLOB());
        $sth->bind_param(4, $f->{content_type});
        $sth->bind_param(5, $f->{size});
        $sth->bind_param(6, $f->{is_binary});
        $sth->bind_param(7, $now);
        $sth->execute;
      }
      $d->do_('UPDATE subpages SET updated_at=? WHERE id=?', $now, $id);
    }
  );
  return ([map {$_->{path}} @ready], undef);
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

  # Scope the structural scan to this directory's subtree via the
  # UNIQUE(subpage_id, path) index, and pull only cheap metadata.
  my $rows;
  if (length $prefix) {
    (my $hi = $prefix) =~ s{/\z}{0};    # half-open upper bound of "$prefix*"
    $rows = $db->all(
      q{SELECT path, size, updated_at, content_type, is_binary
          FROM subpage_files
         WHERE subpage_id=? AND path >= ? AND path < ?
         ORDER BY path}, $id, $prefix, $hi
    );
  }
  else {
    $rows = $db->all(
      q{SELECT path, size, updated_at, content_type, is_binary
          FROM subpage_files WHERE subpage_id=? ORDER BY path}, $id
    );
  }

  my (%dirs, @files);
  for my $r (@$rows) {
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
        type         => 'file',
        name         => $rest,
        size         => $r->{size},
        updated_at   => $r->{updated_at},
        path         => $r->{path},
        content_type => $r->{content_type},
        is_binary    => $r->{is_binary},
        };
    }
  }

  _attach_langs($db, $id, \@files) if @files;

  my @out = map { {type => 'dir', name => $_, updated_at => $dirs{$_}} }
    sort keys %dirs;
  push @out, sort { $a->{name} cmp $b->{name} } @files;
  return \@out;
}

# Set {lang} from the first 8 KB of content, for files whose icon needs
# it. SUBSTR over a BLOB materialises the whole value.
sub _attach_langs {
  my ($db, $id, $files) = @_;

  my @want;
  for my $f (@$files) {
    $f->{lang} = undef;
    next
      if defined icon_from_type($f->{name},
      content_type => $f->{content_type},
      is_binary    => $f->{is_binary});
    push @want, $f;
  }
  return unless @want;

  my @paths = map {$_->{path}}
    grep {!defined $_->{size} || $_->{size} <= SNIFF_MAX_SIZE} @want;
  my %sniff;
  while (@paths) {
    my @chunk = splice @paths, 0, 500;
    my $ph    = join ',', ('?') x @chunk;
    my $heads = $db->all(
      qq{SELECT path, SUBSTR(content, 1, 8192) AS sniff
           FROM subpage_files WHERE subpage_id=? AND path IN ($ph)},
      $id, @chunk
    );
    $sniff{$_->{path}} = $_->{sniff} for @$heads;
  }
  $_->{lang}
    = Iczelia::Highlight::lang_for_file($_->{name}, $sniff{$_->{path}})
    for @want;
}

sub delete {
  my ($db, $id) = @_;
  $db->do_('DELETE FROM subpages WHERE id=?', $id);
}

1;
