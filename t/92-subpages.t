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

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";
use IO::Compress::Zip qw(zip $ZipError);

use Iczelia::DB;
use Iczelia::Subpages;
use Iczelia::Router;
use Iczelia::Server;
use Iczelia::Handlers::Subpages;
use Iczelia::Handlers::Admin::Subpages;

# Build an in-memory zip from { path => content }.
sub make_zip {
  my (%f) = @_;
  my @names = sort keys %f;
  my $out   = '';
  my $z = IO::Compress::Zip->new(\$out, Name => $names[0])
    or die "zip init: $ZipError";
  $z->print($f{$names[0]});
  for my $n (@names[1 .. $#names]) {
    $z->newStream(Name => $n) or die "zip newStream: $ZipError";
    $z->print($f{$n});
  }
  $z->close;
  return $out;
}

# 1. Slug validation.
ok(Iczelia::Subpages::valid_slug('jcram'),     'simple slug');
ok(Iczelia::Subpages::valid_slug('my-page-2'), 'dashes and digits');
ok(!Iczelia::Subpages::valid_slug('Jcram'),       'uppercase rejected');
ok(!Iczelia::Subpages::valid_slug('-x'),          'leading dash rejected');
ok(!Iczelia::Subpages::valid_slug('admin'),       'reserved name rejected');
ok(!Iczelia::Subpages::valid_slug('blog'),        'reserved blog rejected');
ok(!Iczelia::Subpages::valid_slug('assets-foo'),  'assets- prefix rejected');
ok(!Iczelia::Subpages::valid_slug(''),            'empty rejected');
ok(!Iczelia::Subpages::valid_slug('a' x 80),      'overlong rejected');

# 2. Path sanitization.
is(Iczelia::Subpages::sanitize_rel_path('css/style.css'),
  'css/style.css', 'normal path');
is(Iczelia::Subpages::sanitize_rel_path('./a/./b.html'),
  'a/b.html', 'dot segments dropped');
is(Iczelia::Subpages::sanitize_rel_path('a\\b.css'),
  'a/b.css', 'backslash normalized');
is(Iczelia::Subpages::sanitize_rel_path('../evil'), undef,
  'traversal rejected');
is(Iczelia::Subpages::sanitize_rel_path('a/../b'), undef,
  'embedded traversal rejected');
is(Iczelia::Subpages::sanitize_rel_path('/etc/passwd'),
  'etc/passwd', 'leading slash stripped');
is(Iczelia::Subpages::sanitize_rel_path('C:/x'), undef,
  'drive letter rejected');

# 3. Content type + text detection.
is(Iczelia::Subpages::content_type_for('a.html'),
  'text/html; charset=utf-8', 'html content-type');
is(Iczelia::Subpages::content_type_for('a.png'), 'image/png', 'png');
is(Iczelia::Subpages::content_type_for('a.weird'),
  'application/octet-stream', 'unknown extension');
ok(Iczelia::Subpages::is_text_type('text/html; charset=utf-8'),
  'html is text');
ok(!Iczelia::Subpages::is_text_type('image/png'), 'png is not text');

# 4. Zip extraction.
my $zip = make_zip(
  'index.html'    => '<h1>hi</h1>',
  'css/style.css' => 'body{color:red}',
  'logo.png'      => "\x89PNG\x00\x00binary",
);
my ($files, $err) = Iczelia::Subpages::extract_zip($zip);
ok(!$err, 'extract_zip succeeds') or diag $err;
is(scalar @$files, 3, 'three files extracted');
my %byp = map {$_->{path} => $_} @$files;
is($byp{'index.html'}{content},   '<h1>hi</h1>', 'html content intact');
is($byp{'index.html'}{is_binary}, 0,             'html flagged text');
is($byp{'css/style.css'}{content_type},
  'text/css; charset=utf-8', 'css content-type');
is($byp{'logo.png'}{is_binary}, 1, 'NUL-bearing png flagged binary');

my ($f2) = Iczelia::Subpages::extract_zip(
  make_zip('mysite/index.html' => 'X', 'mysite/app.js' => 'Y'));
my %p2 = map {$_->{path} => 1} @$f2;
ok($p2{'index.html'} && $p2{'app.js'}, 'common wrapping folder stripped');

my ($f3) = Iczelia::Subpages::extract_zip(
  make_zip('index.html' => 'ok', '../evil.txt' => 'bad'));
is(scalar @$f3,     1,            'traversal entry dropped');
is($f3->[0]{path}, 'index.html', 'only the safe file kept');

my (undef, $berr) = Iczelia::Subpages::extract_zip('this is not a zip');
ok($berr, 'non-zip input rejected');
my (undef, $eerr) = Iczelia::Subpages::extract_zip('');
ok($eerr, 'empty input rejected');

# 5. DB CRUD.
my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $id = Iczelia::Subpages::create($db, 'jcram', 'JC RAM', $files);
ok($id, 'create returns an id');
is(Iczelia::Subpages::get($db, $id)->{slug}, 'jcram', 'get by id');
is(Iczelia::Subpages::get_by_slug($db, 'jcram')->{id}, $id, 'get by slug');
is(scalar @{Iczelia::Subpages::files($db, $id)}, 3, 'files listed');

my $png = Iczelia::Subpages::file($db, $id, 'logo.png');
is($png->{content}, "\x89PNG\x00\x00binary",
  'binary content survives the NUL-byte roundtrip');
is($png->{is_binary}, 1, 'binary flag persisted');

my $rel = Iczelia::Subpages::put_file($db, $id, 'about.html', '<p>about</p>');
is($rel, 'about.html', 'put_file returns cleaned path');
is(scalar @{Iczelia::Subpages::files($db, $id)}, 4, 'file added');
Iczelia::Subpages::put_file($db, $id, 'about.html', '<p>v2</p>');
is(Iczelia::Subpages::file($db, $id, 'about.html')->{content},
  '<p>v2</p>', 'put_file updates in place');
is(scalar @{Iczelia::Subpages::files($db, $id)}, 4, 'upsert did not duplicate');
is(Iczelia::Subpages::put_file($db, $id, '../x', 'bad'), undef,
  'put_file rejects traversal');

Iczelia::Subpages::delete_file($db, $id, 'about.html');
is(scalar @{Iczelia::Subpages::files($db, $id)}, 3, 'file deleted');

Iczelia::Subpages::replace_files(
  $db, $id,
  [ { path => 'index.html', content => 'NEW',
      content_type => 'text/html; charset=utf-8', size => 3, is_binary => 0 }
  ]
);
is(scalar @{Iczelia::Subpages::files($db, $id)}, 1, 'replace_files swaps bundle');

Iczelia::Subpages::update_meta($db, $id, 'jcram2', 'renamed');
is(Iczelia::Subpages::get($db, $id)->{slug}, 'jcram2', 'update_meta');

Iczelia::Subpages::delete($db, $id);
is(Iczelia::Subpages::get($db, $id), undef, 'subpage deleted');
is($db->one('SELECT COUNT(*) FROM subpage_files'), 0,
  'files cascade-deleted');

# 6. Trailing-slash redirect for router routes.
my $router = Iczelia::Router->new;
$router->get('/about/', sub { {status => 200} });
my $srv = bless {router => $router}, 'Iczelia::Server';

my $rd = Iczelia::Server::_slash_redirect($srv,
  {method => 'GET', path => '/about'});
is($rd->{status}, 301, '/about -> 301');
is($rd->{headers}{Location}, '/about/', 'redirect adds the slash');
is(Iczelia::Server::_slash_redirect($srv, {method => 'GET', path => '/about/'}),
  undef, 'already-slashed path is left alone');
is(Iczelia::Server::_slash_redirect($srv, {method => 'GET', path => '/nope'}),
  undef, 'unknown path is not redirected');
is(Iczelia::Server::_slash_redirect($srv, {method => 'POST', path => '/about'}),
  undef, 'POST is not redirected');
is(
  Iczelia::Server::_slash_redirect(
    $srv, {method => 'GET', path => '/about', query => 'x=1'}
  )->{headers}{Location},
  '/about/?x=1',
  'query string carried over'
);

# 7. Subpage public serving.
my $sid = Iczelia::Subpages::create(
  $db, 'demo', 'Demo',
  [ { path => 'index.html', content => '<h1>home</h1>',
      content_type => 'text/html; charset=utf-8', size => 13, is_binary => 0 },
    { path => 'style.css', content => 'a{}',
      content_type => 'text/css; charset=utf-8', size => 3, is_binary => 0 },
    { path => 'sub/index.html', content => 'SUB',
      content_type => 'text/html; charset=utf-8', size => 3, is_binary => 0 },
  ]
);
my $ctx = FakeCtx->new($db);

my $r1 = Iczelia::Handlers::Subpages::serve($ctx,
  {method => 'GET', path => '/demo/'});
is($r1->{status}, 200,             '/demo/ serves');
is($r1->{body},   '<h1>home</h1>', 'serves index.html by default');

my $r2 = Iczelia::Handlers::Subpages::serve($ctx,
  {method => 'GET', path => '/demo/style.css'});
is($r2->{headers}{'Content-Type'},
  'text/css; charset=utf-8', 'asset served with its content-type');

my $r3 = Iczelia::Handlers::Subpages::serve($ctx,
  {method => 'GET', path => '/demo'});
is($r3->{status}, 301, '/demo -> 301');
is($r3->{headers}{Location}, '/demo/', 'subpage root canonicalised');

is(
  Iczelia::Handlers::Subpages::serve(
    $ctx, {method => 'GET', path => '/demo/nope.html'}
  )->{status},
  404,
  'missing file -> 404'
);
is(Iczelia::Handlers::Subpages::serve($ctx, {method => 'GET', path => '/x/'}),
  undef, 'unknown slug -> undef (falls through)');

is(
  Iczelia::Handlers::Subpages::serve(
    $ctx, {method => 'GET', path => '/demo/sub/'}
  )->{body},
  'SUB',
  'nested directory serves its index.html'
);
is(
  Iczelia::Handlers::Subpages::serve(
    $ctx, {method => 'GET', path => '/demo/sub'}
  )->{status},
  301,
  'nested directory without slash redirects'
);

# 8. Precompressed siblings (brotli_static / gzip_static) for non-HTML.
Iczelia::Subpages::put_file($db, $sid, 'app.js',    'BASE-JAVASCRIPT');
Iczelia::Subpages::put_file($db, $sid, 'app.js.gz', 'PRETEND-GZIP-BYTES');

my $g1 = Iczelia::Handlers::Subpages::serve(
  $ctx,
  { method  => 'GET', path => '/demo/app.js',
    headers => {'accept-encoding' => 'gzip, deflate'} }
);
is($g1->{headers}{'Content-Encoding'}, 'gzip',
  'gz sibling served when the client accepts gzip');
is($g1->{body}, 'PRETEND-GZIP-BYTES', 'precompressed bytes served');
is($g1->{headers}{'Content-Type'}, 'application/javascript; charset=utf-8',
  'content-type is the base file type, not the .gz type');
is($g1->{headers}{Vary}, 'Accept-Encoding', 'Vary: Accept-Encoding set');

my $g2 = Iczelia::Handlers::Subpages::serve($ctx,
  {method => 'GET', path => '/demo/app.js', headers => {}});
is($g2->{headers}{'Content-Encoding'},
  undef, 'no content-encoding when nothing is accepted');
is($g2->{body}, 'BASE-JAVASCRIPT', 'uncompressed base file served instead');

# Brotli is preferred over gzip when the client accepts it.
Iczelia::Subpages::put_file($db, $sid, 'app.js.br', 'PRETEND-BROTLI-BYTES');
my $b1 = Iczelia::Handlers::Subpages::serve(
  $ctx,
  { method  => 'GET', path => '/demo/app.js',
    headers => {'accept-encoding' => 'gzip, deflate, br'} }
);
is($b1->{headers}{'Content-Encoding'}, 'br', 'br sibling preferred over gz');
is($b1->{body}, 'PRETEND-BROTLI-BYTES', 'brotli bytes served');

my $b2 = Iczelia::Handlers::Subpages::serve(
  $ctx,
  { method  => 'GET', path => '/demo/app.js',
    headers => {'accept-encoding' => 'gzip'} }
);
is($b2->{headers}{'Content-Encoding'},
  'gzip', 'gzip-only client still gets the .gz despite a .br sibling');

# HTML is excluded even when a precompressed sibling exists.
Iczelia::Subpages::put_file($db, $sid, 'page.html',    '<h1>real html</h1>');
Iczelia::Subpages::put_file($db, $sid, 'page.html.br', 'HTML-BROTLI-BYTES');
my $g3 = Iczelia::Handlers::Subpages::serve(
  $ctx,
  { method  => 'GET', path => '/demo/page.html',
    headers => {'accept-encoding' => 'gzip, br'} }
);
is($g3->{headers}{'Content-Encoding'}, undef, 'html is not statically encoded');
is($g3->{body}, '<h1>real html</h1>', 'html served uncompressed');

# A .br-only asset with no uncompressed sibling.
Iczelia::Subpages::put_file($db, $sid, 'data.bin.br', 'ONLY-BROTLI');
is(
  Iczelia::Handlers::Subpages::serve(
    $ctx,
    { method  => 'GET', path => '/demo/data.bin',
      headers => {'accept-encoding' => 'br'} }
  )->{body},
  'ONLY-BROTLI',
  'br-only asset served to a brotli client'
);
is(
  Iczelia::Handlers::Subpages::serve(
    $ctx,
    { method  => 'GET', path => '/demo/data.bin',
      headers => {'accept-encoding' => 'gzip'} }
  )->{status},
  404,
  'br-only asset 404s a client that only accepts gzip'
);

# 9. _bundle_bytes: importing a .zip already on the server's filesystem.
{
  my $zipbytes = make_zip('index.html' => '<h1>imported</h1>');
  my $zippath  = "$tmp/import.zip";
  open my $zf, '>:raw', $zippath or die "write $zippath: $!";
  print $zf $zipbytes;
  close $zf;

  my ($b, $e, $from_fs) = Iczelia::Handlers::Admin::Subpages::_bundle_bytes(
    {uploads => [], params => {zip_path => $zippath}});
  is($e, undef, 'fs import: no error for a readable zip');
  is($b, $zipbytes, 'fs import: returns the file bytes verbatim');
  is($from_fs, 1, 'fs import: flagged as a filesystem import');
  my ($ef) = Iczelia::Subpages::extract_zip($b);
  is($ef->[0]{path}, 'index.html', 'fs-imported bytes extract correctly');

  my (undef, $e2) = Iczelia::Handlers::Admin::Subpages::_bundle_bytes(
    {uploads => [], params => {zip_path => 'relative/path.zip'}});
  ok($e2, 'fs import: a relative path is rejected');

  my (undef, $e3) = Iczelia::Handlers::Admin::Subpages::_bundle_bytes(
    {uploads => [], params => {zip_path => "$tmp/does-not-exist.zip"}});
  ok($e3, 'fs import: a missing file is rejected');

  my (undef, $e4) = Iczelia::Handlers::Admin::Subpages::_bundle_bytes(
    {uploads => [], params => {zip_path => "$tmp"}});
  ok($e4, 'fs import: a directory is rejected');

  my ($b5, $e5) = Iczelia::Handlers::Admin::Subpages::_bundle_bytes(
    {uploads => [], params => {}});
  ok(!defined $b5 && !defined $e5,
    'fs import: nothing supplied yields (undef, undef)');

  my ($b6, undef, $up_fs) = Iczelia::Handlers::Admin::Subpages::_bundle_bytes(
    {uploads => [{body => 'UPLOADED'}], params => {zip_path => $zippath}});
  is($b6, 'UPLOADED', 'fs import: an uploaded file wins over the path');
  ok(!$up_fs, 'fs import: an upload is not flagged as a filesystem import');
}

# 10. extract_zip: a filesystem import bypasses the bundle caps.
{
  my %many = map {("f$_.txt" => 'x')} 1 .. (Iczelia::Subpages::MAX_FILES + 1);
  my $bigzip = make_zip(%many);
  my (undef, $capped) = Iczelia::Subpages::extract_zip($bigzip);
  ok($capped, 'extract_zip enforces the file-count cap by default');
  my ($uncapped, $uerr) =
    Iczelia::Subpages::extract_zip($bigzip, unlimited => 1);
  is($uerr, undef, 'unlimited extract bypasses the cap');
  is(scalar @$uncapped, Iczelia::Subpages::MAX_FILES + 1,
    'unlimited extract keeps every file');
}

done_testing;

package FakeCtx;
sub new {bless {db => $_[1]}, $_[0]}
sub db  {$_[0]{db}}
