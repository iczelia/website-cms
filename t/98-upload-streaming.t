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

# Coverage for the chunked-upload / streaming-response pipeline that
# replaced the request-cap kludges: HTTP streaming, TarStream,
# Iczelia::Upload, backup export streaming, backup import via
# upload_id.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::HTTP;
use Iczelia::TarStream;
use Iczelia::Upload;
use Iczelia::Handlers::Backup;

# --- 1. HTTP streaming ------------------------------------------------------

{
  my $buf = '';
  open my $sink, '>', \$buf or die "open scalar: $!";
  binmode $sink;
  my $resp = {
    status  => 200,
    headers => { 'Content-Type' => 'application/x-tar',
                 'X-Test'        => 'streamed' },
    stream  => sub {
      my ($w) = @_;
      $w->('hello ');
      $w->('world');
      $w->('');     # zero-length: must NOT emit a 0-chunk terminator
      $w->("\xff\x00\xfe");
    },
  };
  Iczelia::HTTP::write_response($sink, $resp);
  close $sink;

  like($buf, qr/\AHTTP\/1\.1 200 OK\r\n/, 'status line emitted first');
  like($buf, qr/^Transfer-Encoding: chunked\r\n/m,
    'Transfer-Encoding: chunked header set');
  unlike($buf, qr/^Content-Length:/m,
    'Content-Length removed for streamed responses');
  like($buf, qr/^X-Test: streamed\r\n/m, 'custom header preserved');
  like($buf, qr/^Connection: close\r\n/m,
    'Connection: close (streaming forbids keepalive)');

  # Body: each writer call -> "<hex-len>\r\n<bytes>\r\n", with the
  # 0-byte chunk skipped and a terminator 0\r\n\r\n at the end.
  my ($body) = $buf =~ /\r\n\r\n(.*)/s;
  like($body, qr/\A6\r\nhello \r\n5\r\nworld\r\n3\r\n.{3}\r\n0\r\n\r\n\z/s,
    'chunk frames + terminator are byte-exact');
}

# A handler that dies mid-stream still emits the terminator so the
# client doesn't hang on the half-streamed response.
{
  my $buf = '';
  open my $sink, '>', \$buf;
  binmode $sink;
  Iczelia::HTTP::write_response($sink, {
    status  => 200,
    headers => { 'Content-Type' => 'text/plain' },
    stream  => sub {
      my ($w) = @_;
      $w->('partial');
      die "oh no\n";
    },
  });
  close $sink;
  like($buf, qr/7\r\npartial\r\n0\r\n\r\n\z/,
    'terminator written even when stream coderef dies');
}

# --- 2. TarStream -----------------------------------------------------------

{
  my $buf = '';
  my $ts = Iczelia::TarStream->new(write => sub { $buf .= $_[0] });
  $ts->add_data('foo.txt', "hello\n");
  $ts->add_data('bar.bin', "X" x 1500);
  my $longname = 'media/' . ('a' x 200) . '.dat';
  $ts->add_data($longname, "deadbeef");

  # Round-trip a filehandle entry.
  my $tmpfh = File::Temp->new(SUFFIX => '.bin');
  binmode $tmpfh;
  print $tmpfh "fhdata-12345";
  $tmpfh->flush;
  seek($tmpfh, 0, 0);
  $ts->add_fh('streamed.bin', $tmpfh, 12);

  $ts->finish;

  # Length is always a multiple of 512.
  is(length($buf) % 512, 0, 'tar stream rounds to 512-byte blocks');
  # Final two blocks are zeros.
  is(substr($buf, -1024), "\0" x 1024, 'archive ends with 2 zero blocks');

  # Round-trip through Archive::Tar from a file (avoids the
  # SCALAR-ref quirks of older Archive::Tar releases).
  my $path = File::Temp->new(SUFFIX => '.tar');
  binmode $path;
  print $path $buf;
  $path->flush;
  close $path;

  require Archive::Tar;
  my $tar = Archive::Tar->new;
  $tar->read($path->filename);
  my %seen = map { $_->name => $_ } $tar->get_files;
  ok(exists $seen{'foo.txt'},      'foo.txt round-trips');
  is($seen{'foo.txt'}->get_content, "hello\n", 'foo.txt content matches');
  is($seen{'bar.bin'}->size, 1500, 'bar.bin size matches');
  ok(exists $seen{$longname}, 'long-name entry round-trips through GNU L');
  is($seen{'streamed.bin'}->get_content, 'fhdata-12345',
    'filehandle entry content matches');
}

# --- 3. Iczelia::Upload -----------------------------------------------------

my $tmpdir = File::Temp->newdir;
my $db = Iczelia::DB->connect("$tmpdir/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $u = Iczelia::Upload->new(
  db       => $db,
  tmp_dir  => "$tmpdir/uptmp",
  max_size => 8192,                # small for cap-test ergonomics
);

# Happy path.
my $sid = 'admin-sid-1';
my $id  = $u->init($sid, filename => 'foo.bin');
ok($id && $id =~ /^[0-9a-f]+\z/ && length($id) >= 32,
  'init returns a hex id');

my ($size1, $err1) = $u->append($id, $sid, 0, 'AAAA');
is($err1, undef, 'first chunk appends');
is($size1, 4,    'size after first chunk');

my ($size2, $err2) = $u->append($id, $sid, 4, 'BBBB');
is($err2, undef, 'second chunk appends');
is($size2, 8,    'size after second chunk');

# Offset mismatch (gap or duplicate).
my (undef, $gap_err) = $u->append($id, $sid, 16, 'CCCC');
like($gap_err, qr/offset/i, 'gap in offset is rejected');

# Wrong sid.
my (undef, $sid_err) = $u->append($id, 'someone-else', 8, 'CCCC');
like($sid_err, qr/not your upload/, 'sid mismatch is rejected');

# Size cap.
my (undef, $cap_err) = $u->append($id, $sid, 8, 'C' x 9000);
like($cap_err, qr/cap exceeded|chunk too large/i,
  'oversize chunk hits a cap');

# Finalize + claim.
my ($fsize, $ferr) = $u->finalize($id, $sid);
is($ferr, undef, 'finalize ok');
is($fsize, 8,    'finalize returns assembled size');

# After finalize, no more appends.
my (undef, $closed_err) = $u->append($id, $sid, 8, 'CC');
like($closed_err, qr/finalized/, 'append after finalize is refused');

# Claim returns a real on-disk path with the right bytes.
my ($path, $cerr) = $u->claim($id, $sid);
is($cerr, undef, 'claim returns no error');
ok(-f $path,     'claim returns a real path');
{
  open my $fh, '<:raw', $path or die "open $path: $!";
  local $/;
  my $bytes = <$fh>;
  close $fh;
  is($bytes, 'AAAABBBB', 'claimed file holds the assembled bytes');
}

# Cleanup nukes both row and file.
$u->cleanup($id, $sid);
ok(!-e $path, 'cleanup removes the file');
is($u->size_of($id, $sid), undef, 'cleanup removes the row');

# A different sid cannot cleanup someone else's session.
my $id2 = $u->init($sid);
$u->cleanup($id2, 'a-different-sid');
ok($u->size_of($id2, $sid) == 0,
  'cleanup with wrong sid is a no-op');
$u->cleanup($id2, $sid);

# --- 4. Backup export: streamed handler ------------------------------------

# A minimal ctx that satisfies the backup handler's dependencies.
my $ctx = MockCtx->new(
  db      => $db,
  tmp_dir => "$tmpdir/btmp",
  media   => "$tmpdir/media",
);

# Seed a stub admin row so any auth touch points work in future tests.
$db->do_(q{INSERT INTO auth(username, pwhash) VALUES(?,?)},
  'admin', 'x');

# Stage a media file so the export has something to bundle.
mkdir "$tmpdir/media";
{
  open my $fh, '>:raw', "$tmpdir/media/logo.png" or die;
  print $fh "\x89PNGfake-payload";
  close $fh;
}

# Sign a CSRF token the handler will accept.
my $auth = MockAuth->new('export-sid');
$ctx->{auth} = $auth;

my $req = {
  method   => 'POST',
  path     => '/admin/backup/export',
  params   => { csrf => $auth->csrf_token('export-sid', 'backup:export') },
  auth_sid => 'export-sid',
};
my $resp = Iczelia::Handlers::Backup::_export($ctx, $req);
is($resp->{status}, 200, 'export handler returns 200');
ok(ref($resp->{stream}) eq 'CODE', 'export uses streaming response');
ok($resp->{_no_cache}, 'export is uncacheable');
like($resp->{headers}{'Content-Disposition'},
  qr/filename="iczelia-backup-\d{4}-\d{2}-\d{2}\.tar"/,
  'export filename stamp looks right');

# Drive the stream by hand, collecting all chunks into one buffer.
my $tar_bytes = '';
$resp->{stream}->(sub {
  my ($data) = @_;
  $tar_bytes .= $data if defined $data;
});

# Round-trip through Archive::Tar via disk (older Archive::Tar
# implementations choke on SCALAR refs).
my $tarpath = "$tmpdir/exported.tar";
open my $tfh, '>:raw', $tarpath or die;
print $tfh $tar_bytes;
close $tfh;

require Archive::Tar;
my $rd = Archive::Tar->new;
$rd->read($tarpath);
my %got = map { $_->name => $_ } $rd->get_files;
ok($got{'site.db'},       'site.db present in exported tar');
ok($got{'MANIFEST.json'}, 'MANIFEST.json present');
ok($got{'media/logo.png'}, 'media file present');
is($got{'media/logo.png'}->get_content, "\x89PNGfake-payload",
  'media bytes byte-identical');

# --- 5. Backup import via upload_id ----------------------------------------

# Build a fresh import target (separate DB so we don't disturb the
# export ctx). The import handler swaps the live DB; spin up a
# disposable instance for the round-trip.
my $tdir = File::Temp->newdir;
my $idb_path = "$tdir/site.db";
my $idb = Iczelia::DB->connect($idb_path);
$idb->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$idb->do_(q{INSERT INTO auth(username, pwhash) VALUES(?,?)}, 'a', 'b');

my $iauth = MockAuth->new('import-sid');
my $ictx  = MockCtx->new(
  db => $idb, tmp_dir => "$tdir/btmp",
  media => "$tdir/media",
);
$ictx->{auth} = $iauth;
mkdir "$tdir/btmp";
mkdir "$tdir/media";

# Stage the tar we just exported via the chunked upload pipe.
my $iup = Iczelia::Upload->new(db => $idb, tmp_dir => "$tdir/btmp");
my $up_id = $iup->init('import-sid');
# Push in two halves so we exercise multi-chunk append.
my $half = int(length($tar_bytes) / 2);
$iup->append($up_id, 'import-sid', 0, substr($tar_bytes, 0, $half));
$iup->append($up_id, 'import-sid', $half, substr($tar_bytes, $half));

my $ireq = {
  method   => 'POST',
  path     => '/admin/backup/import',
  params   => {
    csrf      => $iauth->csrf_token('import-sid', 'backup:import'),
    upload_id => $up_id,
  },
  auth_sid => 'import-sid',
  uploads  => [],
};
my $iresp = Iczelia::Handlers::Backup::_import($ictx, $ireq);
is($iresp->{status}, 303, 'import via upload_id returns 303 redirect')
  or diag explain $iresp;
like($iresp->{headers}{Location}, qr{/admin/backup/\?msg=imported},
  'import redirects to the success page');

# Upload session is gone after the handler claims it.
is($iup->size_of($up_id, 'import-sid'), undef,
  'upload session cleaned up after import');

# The new live DB is the snapshot we exported (has the auth row from
# the export side).
my $live = Iczelia::DB->connect($idb_path);
my $auth_users = $live->all('SELECT username FROM auth');
ok(scalar(grep { $_->{username} eq 'admin' } @$auth_users),
  'imported DB carries the export-side admin user');
my $imported_media = "$tdir/media/logo.png";
ok(-f $imported_media, 'imported media file landed on disk');

done_testing;

# --- helpers ----------------------------------------------------------------

package MockCtx;
sub new {
  my ($class, %a) = @_;
  bless {
    db    => $a{db},
    cfg   => { 'tmp-dir' => $a{tmp_dir}, 'media-dir' => $a{media} },
    render => MockRender->new,
  }, $class;
}
sub db    { $_[0]{db} }
sub cfg   { $_[0]{cfg} }
sub auth  { $_[0]{auth} }
sub render { $_[0]{render} }

package MockRender;
sub new            { bless {}, shift }
sub invalidate_all { }

package MockAuth;
# Self-consistent CSRF tokens: any (sid, form_name) pair has one
# deterministic token. The handler validates via require_csrf which
# calls verify_csrf; we implement both.
sub new {
  my ($class, $sid) = @_;
  bless { sid => $sid }, $class;
}
sub csrf_token {
  my ($self, $sid, $form) = @_;
  return "tok:$sid:$form";
}
sub verify_csrf {
  my ($self, $sid, $form, $tok) = @_;
  return defined $tok && $tok eq "tok:$sid:$form";
}
sub require_csrf {
  my ($self, $req, $form) = @_;
  my $tok = $req->{params}{csrf} // '';
  return undef if $self->verify_csrf($req->{auth_sid}, $form, $tok);
  return { status => 400, headers => { 'Content-Type' => 'text/plain' },
           body   => 'csrf' };
}
