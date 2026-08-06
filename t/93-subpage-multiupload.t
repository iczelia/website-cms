# iczelia.net - personal CMS and static site engine.
# Copyright (C) 2026 Kamila Szewczyk

use strict;
use warnings;
use Test::More;
use File::Temp ();
use JSON::PP   ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Subpages;
use Iczelia::Upload;
use Iczelia::Handlers::Admin::Subpages;

my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
my $id = Iczelia::Subpages::create($db, 'multi', 'Multi', [
  {
    path => 'index.html', content => 'home',
    content_type => 'text/html; charset=utf-8', size => 4, is_binary => 0,
  },
]);

{
  package MultiUploadAuth;
  sub require_csrf { undef }
}
{
  package MultiUploadCtx;
  sub new { bless {db => $_[1], cfg => $_[2], auth => bless({}, 'MultiUploadAuth'),
                   render => bless({busted => []}, 'MultiUploadRender')}, $_[0] }
  sub db     { $_[0]{db} }
  sub cfg    { $_[0]{cfg} }
  sub auth   { $_[0]{auth} }
  sub render { $_[0]{render} }

  package MultiUploadRender;
  sub invalidate_subpage { my $s = shift; push @{$s->{busted}}, @_ }
  sub busted { $_[0]{busted} }
}

my $ctx = MultiUploadCtx->new($db, {'tmp-dir' => "$tmp/uploads"});

sub req {
  my (%arg) = @_;
  return {
    caps     => {id => $id},
    params   => $arg{params} || {},
    uploads  => $arg{uploads} || [],
    auth_sid => 'admin-session',
  };
}

# put_files validates the entire selection before opening its transaction.
my ($bad_paths, $bad_err) = Iczelia::Subpages::put_files($db, $id, [
  {path => 'atomic/good.txt', content => 'good'},
  {path => '../bad.txt',     content => 'bad'},
]);
ok(!$bad_paths && $bad_err, 'invalid batch rejected');
is(Iczelia::Subpages::file($db, $id, 'atomic/good.txt'), undef,
  'invalid batch leaves no partial upload');

# Classic multipart fallback: multiple files land in the open directory,
# while a directory input preserves its relative tree.
my $resp = Iczelia::Handlers::Admin::Subpages::_file_upload($ctx, req(
  params => {dir => 'assets', csrf => 'ok'},
  uploads => [
    {name => 'files', filename => 'one.txt', body => 'one'},
    {name => 'files', filename => 'two.css', body => 'two'},
    {name => 'directory', filename => 'site/js/app.js', body => 'app'},
  ],
));
ok($resp->{status} >= 300 && $resp->{status} < 400,
  'multipart multi-file upload redirects');
is(Iczelia::Subpages::file($db, $id, 'assets/one.txt')->{content}, 'one',
  'first selected file stored');
is(Iczelia::Subpages::file($db, $id, 'assets/two.css')->{content}, 'two',
  'second selected file stored');
is(Iczelia::Subpages::file($db, $id, 'assets/site/js/app.js')->{content}, 'app',
  'directory relative path preserved');

# Real browsers submit the unused second picker as filename="" with an empty
# body. It must not turn a one-file upload into a contradictory multi-file
# path-override error.
$resp = Iczelia::Handlers::Admin::Subpages::_file_upload($ctx, req(
  params => {dir => '', csrf => 'ok', path => 'images/pastel.svg'},
  uploads => [
    {name => 'files', filename => 'pastel.svg', body => '<svg/>'},
    {name => 'directory', filename => '', body => ''},
  ],
));
ok($resp->{status} >= 300 && $resp->{status} < 400,
  'unused picker placeholder does not make one file look like a batch');
is(Iczelia::Subpages::file($db, $id, 'images/pastel.svg')->{content}, '<svg/>',
  'single pastel.svg upload with path override succeeds');

# JS batches send a path array parallel to the upload parts.
$resp = Iczelia::Handlers::Admin::Subpages::_file_upload($ctx, req(
  params => {
    dir => 'nested', csrf => 'ok', batch => 1,
    paths => JSON::PP::encode_json(['picked/a.txt', 'picked/b.txt']),
  },
  uploads => [
    {name => 'files', filename => 'a.txt', body => 'A'},
    {name => 'files', filename => 'b.txt', body => 'B'},
  ],
));
is($resp->{status}, 200, 'JS batch returns JSON success');
my $json = JSON::PP::decode_json($resp->{body});
is($json->{count}, 2, 'JSON reports both files');
is(Iczelia::Subpages::file($db, $id, 'nested/picked/a.txt')->{content}, 'A',
  'first JS relative path stored below current directory');
is(Iczelia::Subpages::file($db, $id, 'nested/picked/b.txt')->{content}, 'B',
  'second JS relative path stored below current directory');

# The legacy one-file path override remains bundle-root-relative when it
# contains a slash, even if the uploader is opened in a nested directory.
$resp = Iczelia::Handlers::Admin::Subpages::_file_upload($ctx, req(
  params => {dir => 'nested', csrf => 'ok', path => 'root/renamed.txt'},
  uploads => [{name => 'files', filename => 'local.txt', body => 'renamed'}],
));
ok($resp->{status} >= 300 && $resp->{status} < 400,
  'single-file path override still redirects');
is(Iczelia::Subpages::file($db, $id, 'root/renamed.txt')->{content}, 'renamed',
  'slash-containing override stays bundle-root-relative');
is(Iczelia::Subpages::file($db, $id, 'nested/root/renamed.txt'), undef,
  'root-relative override is not prefixed with the open directory');

# A resumable upload larger than the native 8 MiB per-file limit is claimed
# and inserted only when its final request arrives.
my $large = ('L' x Iczelia::Subpages::MAX_FILE) . 'Z';
my $u = Iczelia::Upload->new(db => $db, tmp_dir => "$tmp/uploads");
my $upload_id = $u->init('admin-session', filename => 'large.bin');
my ($n1, $e1) = $u->append($upload_id, 'admin-session', 0,
  substr($large, 0, Iczelia::Upload::MAX_CHUNK));
is($e1, undef, 'large upload first chunk accepted');
my ($n2, $e2) = $u->append($upload_id, 'admin-session', $n1,
  substr($large, $n1));
is($e2, undef, 'large upload final chunk accepted');
is($n2, length($large), 'chunk session assembled the full large file');

$resp = Iczelia::Handlers::Admin::Subpages::_file_upload($ctx, req(
  params => {
    dir => 'downloads', csrf => 'ok', batch => 1,
    upload_id => $upload_id,
    paths => JSON::PP::encode_json(['huge/large.bin']),
  },
));
is($resp->{status}, 200, 'large chunked file finalized');
my $large_row = Iczelia::Subpages::file($db, $id,
  'downloads/huge/large.bin');
is($large_row->{size}, length($large), 'large file stored at full size');
is(substr($large_row->{content}, -1), 'Z', 'large file content intact');
is($u->size_of($upload_id, 'admin-session'), undef,
  'temporary upload session cleaned after finalization');

open my $tpl_fh, '<:raw',
  "$FindBin::Bin/../share/templates/views/admin_subpages_edit.tpl"
  or die "open subpage edit template: $!";
local $/;
my $tpl = <$tpl_fh>;
close $tpl_fh;
like($tpl, qr{name="files"[^>]*\bmultiple\b},
  'panel exposes a multiple-file picker');
like($tpl, qr{name="directory"[^>]*\bwebkitdirectory\b},
  'panel exposes a directory picker');
like($tpl, qr{id="cms-subpage-upload-status"},
  'panel includes live batch progress');

done_testing;
