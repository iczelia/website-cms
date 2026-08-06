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

# Subpages are served out of the response cache. Two things must hold:
# a listing never reads blobs it does not use, and every mutation drops
# the whole /<slug>/ prefix.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Cache;
use Iczelia::Subpages;
use Iczelia::CachePolicy;
use Iczelia::Render::Invalidate;
use Iczelia::Handlers::Subpages;

my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

sub f {
  my ($path, $content, %o) = @_;
  return {
    path         => $path,
    content      => $content,
    content_type => $o{ct} // 'text/plain; charset=utf-8',
    size         => length($content),
    is_binary    => $o{bin} ? 1 : 0,
  };
}

# 1. SUBSTR over a BLOB materialises the whole value, so a sniff costs
# the full file. Media settles from the content type and must not be read.

my $big = 'x' x 200_000;
my $id  = Iczelia::Subpages::create($db, 'bundle', 'B', [
  f('song.flac',   $big, ct => 'audio/flac',       bin => 1),
  f('paper.pdf',   $big, ct => 'application/pdf',  bin => 1),
  f('photo.png',   $big, ct => 'image/png',        bin => 1),
  f('bundle.zip',  $big, ct => 'application/zip',  bin => 1),
  f('script',      "#!/usr/bin/perl\nmy \$x = 1;\n"),
  f('notes.txt',   "# -*- mode: python -*-\nx = 1\n"),
]);

# Which paths the listing actually pulls content for.
my @sniffed;
my $orig = \&Iczelia::DB::all;
{
  no warnings 'redefine';
  *Iczelia::DB::all = sub {
    push @sniffed, @_[3 .. $#_] if $_[1] =~ /SUBSTR\s*\(\s*content/i;
    return $orig->(@_);
  };
}
my $entries = Iczelia::Subpages::directory_entries($db, $id, '');
{
  no warnings 'redefine';
  *Iczelia::DB::all = $orig;
}

is_deeply([sort @sniffed], ['notes.txt', 'script'],
  'listing reads only the files whose icon turns on the language');
my %icon = map {
  $_->{name} => Iczelia::Subpages::icon_for_entry($_->{name},
    content_type => $_->{content_type},
    is_binary    => $_->{is_binary},
    lang         => $_->{lang})
} @$entries;

is($icon{'song.flac'},  'audio.png',   'flac icon from content type');
is($icon{'paper.pdf'},  'pdf.png',     'pdf icon from content type');
is($icon{'photo.png'},  'image.png',   'png icon from content type');
is($icon{'bundle.zip'}, 'archive.png', 'zip icon from content type');

# 'script' is perl only by its shebang, notes.txt python only by its
# modeline; both need the sniff.
is($icon{'script'},    'perl.png',   'shebang still detected');
is($icon{'notes.txt'}, 'python.png', 'modeline still detected');

is(scalar(grep {defined $_->{lang}} @$entries), 2,
  'only the two sniffable files carry a lang');

# 2. Past SNIFF_MAX_SIZE, detection falls back to the name.
my $huge = ('a' x (Iczelia::Subpages::SNIFF_MAX_SIZE + 1));
Iczelia::Subpages::put_file($db, $id, 'huge.txt', $huge);
my $after = Iczelia::Subpages::directory_entries($db, $id, '');
my ($h) = grep {$_->{name} eq 'huge.txt'} @$after;
ok($h, 'oversized text file still listed');
is($h->{lang}, Iczelia::Highlight::lang_for_filename('huge.txt'),
  'oversized file falls back to name-based language');

# 3. cache_control_for sees only the path, and every bundle URL sits
# under one wildcard prefix, so the handler's headers must round-trip.

my $cache = Iczelia::Cache->new(db => $db, compress => 0);
my $stored = $cache->put(
  '/bundle/',
  {
    status  => 200,
    headers => {
      'Content-Type'  => 'text/html; charset=utf-8',
      'Cache-Control' => Iczelia::Handlers::Subpages::CACHE_CONTROL,
      'Vary'          => 'Cookie',
    },
    body => '<!doctype html><p>index</p>',
  }
);
ok($stored, 'subpage listing is storable');
is($stored->{headers}{'Cache-Control'},
  Iczelia::Handlers::Subpages::CACHE_CONTROL,
  'store keeps the handler Cache-Control');
like($stored->{headers}{Vary}, qr/\bCookie\b/, 'store keeps Vary: Cookie');
like($stored->{headers}{Vary}, qr/\bAccept-Encoding\b/,
  'store still adds Accept-Encoding to Vary');

my $hit = $cache->get('/bundle/', {headers => {}});
ok($hit, 'listing comes back out of the cache');
is($hit->{headers}{'Cache-Control'},
  Iczelia::Handlers::Subpages::CACHE_CONTROL,
  'hit replays the handler Cache-Control');
like($hit->{headers}{Vary}, qr/\bCookie\b/, 'hit replays Vary: Cookie');

# must-revalidate is only honest if the conditional GET works.
my $etag = $hit->{headers}{ETag};
$etag =~ s/"//g;
my $not_mod = $cache->get('/bundle/', {headers => {'if-none-match' => $etag}});
is($not_mod->{status}, 304, 'matching ETag revalidates to 304');
is($not_mod->{headers}{'Cache-Control'},
  Iczelia::Handlers::Subpages::CACHE_CONTROL,
  '304 keeps the client revalidating rather than pinning its copy');

# No stated policy keeps the path-derived default.
$cache->put('/blog/',
  {status => 200, headers => {'Content-Type' => 'text/html'}, body => 'x' x 300});
is($cache->get('/blog/', {headers => {}})->{headers}{'Cache-Control'},
  Iczelia::CachePolicy::cache_control_for('/blog/'),
  'unstated policy still falls back to cache_control_for');

# 4. Invalidation drops every URL the bundle owns, and nothing else.

my $render = bless {db => $db, cache => $cache}, 'Iczelia::Render::Invalidate';
sub cached { [sort @{$db->col('SELECT path FROM response_cache ORDER BY path')}] }

$cache->put('/bundle/a.css',
  {status => 200, headers => {'Content-Type' => 'text/css'}, body => 'a{}' x 200});
$cache->put('/bundle/deep/i.html',
  {status => 200, headers => {'Content-Type' => 'text/html'}, body => 'x' x 300});
is_deeply(cached(), ['/blog/', '/bundle/', '/bundle/a.css', '/bundle/deep/i.html'],
  'bundle URLs cached alongside an unrelated page');

$render->invalidate_subpage('bundle');
is_deeply(cached(), ['/blog/'],
  'invalidate_subpage drops the whole prefix and leaves other pages alone');

# A rename must drop the old prefix too; those URLs now 404.
$cache->put('/bundle/a.css',
  {status => 200, headers => {'Content-Type' => 'text/css'}, body => 'a{}' x 200});
$cache->put('/renamed/a.css',
  {status => 200, headers => {'Content-Type' => 'text/css'}, body => 'a{}' x 200});
$render->invalidate_subpage('renamed', 'bundle');
is_deeply(cached(), ['/blog/'], 'rename drops both the old and the new prefix');

# A slug that prefixes another must not take its neighbour down.
$cache->put('/bundle/a.css',
  {status => 200, headers => {'Content-Type' => 'text/css'}, body => 'a{}' x 200});
$cache->put('/bundle2/a.css',
  {status => 200, headers => {'Content-Type' => 'text/css'}, body => 'a{}' x 200});
$render->invalidate_subpage('bundle');
is_deeply(cached(), ['/blog/', '/bundle2/a.css'],
  'busting /bundle/ leaves /bundle2/ intact');

# 5. Bodies the cache would not earn its keep on opt out.

sub cacheable {
  my ($ct, $body) = @_;
  return Iczelia::Handlers::Subpages::_cacheable(
    {status => 200, headers => {'Content-Type' => $ct}, body => $body});
}

my $small = cacheable('text/html; charset=utf-8', 'x' x 1024);
ok(!$small->{_no_cache}, 'small text bundle file is cacheable');
is($small->{headers}{'Cache-Control'},
  Iczelia::Handlers::Subpages::CACHE_CONTROL, 'and carries the policy');

my $fat = cacheable('text/html; charset=utf-8',
  'x' x (Iczelia::Handlers::Subpages::CACHE_MAX_BODY + 1));
ok($fat->{_no_cache}, 'oversized bundle file opts out of the cache');
is($fat->{headers}{'Cache-Control'}, 'no-cache',
  'and says so in the header, so put() refuses it too');
ok(!$cache->put('/bundle/big.bin', $fat), 'put() honours the opt-out');

# The size cap alone misses media: a photo bundle is all small files.
for my $ct ('image/png', 'audio/flac', 'video/mp4', 'application/pdf',
  'font/woff2', 'application/zip')
{
  ok(cacheable($ct, 'x' x 4096)->{_no_cache}, "$ct is served uncached");
}
ok(!cacheable('text/css; charset=utf-8', 'x' x 4096)->{_no_cache},
  'but bundle CSS, where minify and brotli are the real cost, is cached');

# 6. The README is the one blob a listing reads whole, so it is capped.

{
  package ListCtx;
  sub new { bless {db => $_[1]}, $_[0] }
  sub db  { $_[0]{db} }
}
my $lctx = ListCtx->new($db);

sub listing_of {
  my ($slug) = @_;
  return Iczelia::Handlers::Subpages::serve($lctx,
    {method => 'GET', path => "/$slug/", headers => {}, cookies => {}});
}

my $rid = Iczelia::Subpages::create($db, 'readmes', 'R',
  [f('readme.txt', "the readme body\n")]);
$db->do_('UPDATE subpages SET listing=1 WHERE id=?', $rid);
like(listing_of('readmes')->{body}, qr/the readme body/,
  'a normal README renders above the listing');

Iczelia::Subpages::put_file($db, $rid, 'readme.txt',
  'y' x (Iczelia::Subpages::SNIFF_MAX_SIZE + 1));
my $capped = listing_of('readmes');
is($capped->{status}, 200, 'an oversized README still leaves a usable listing');
unlike($capped->{body}, qr/yyyy/, 'but its body is not read or rendered');
like($capped->{body}, qr/readme\.txt/, 'it is still listed as a file');

done_testing;
