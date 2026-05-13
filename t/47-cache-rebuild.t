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

use Iczelia::DB;
use Iczelia::Template;
use Iczelia::Render;
use Iczelia::Handlers::Admin;
use Iczelia::Warmer;

my $tmpdir = File::Temp->newdir;
my $dbpath = "$tmpdir/test.db";

my $cfg = {
  db           => $dbpath,
  'share-dir'  => "$FindBin::Bin/../share",
  'chrome-dir' => "$FindBin::Bin/../share/chrome",
  'tmp-dir'    => "$tmpdir/tmp",
  'media-dir'  => "$tmpdir/media",
};
mkdir $cfg->{'tmp-dir'};
mkdir $cfg->{'media-dir'};

my $db = Iczelia::DB->connect($cfg);
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->apply_schema_file("$FindBin::Bin/../share/seed.sql");

$db->set_setting('cache.rebuild.scope', 'all');

$db->do_(
  q{INSERT INTO posts(kind, slug, title, date, body, updated_at)
       VALUES('blog','first','first post','2026-04-20','# hi\n\nbody one',
              strftime('%s','now'))}
);
$db->do_(
  q{INSERT INTO posts(kind, slug, title, date, body, updated_at)
       VALUES('blog','second','second post','2026-04-21','# yo\n\nbody two',
              strftime('%s','now'))}
);
$db->do_(
  q{INSERT INTO posts(kind, slug, title, date, body, draft, updated_at)
       VALUES('blog','draft','draft post','2026-04-22','draft body',1,
              strftime('%s','now'))}
);

# Sanity: rendered_html is NULL before rebuild.
is_deeply(
  $db->col('SELECT rendered_html FROM posts ORDER BY id'),
  [undef, undef, undef],
  'all posts start with NULL rendered_html'
);

# Pre-populate response_cache and tex_cache so we can confirm _run_rebuild
# drops them.
$db->do_(
  q{INSERT INTO response_cache(path,status,content_type,body,etag,created_at)
       VALUES('/stale/',200,'text/html',CAST('x' AS BLOB),'abc',
              strftime('%s','now'))}
);
$db->do_(
  q{INSERT INTO tex_cache(hash,display,html,created_at)
       VALUES('deadbeef',0,'<svg/>',strftime('%s','now'))}
);
$db->do_(
  q{UPDATE pages SET rendered_html='stale chrome' WHERE slug='home'}
);

is($db->one('SELECT COUNT(*) FROM response_cache'), 1, 'response_cache seeded');
is($db->one('SELECT COUNT(*) FROM tex_cache'),      1, 'tex_cache seeded');

# Run the rebuild end-to-end (in-process; this is the same code the
# detached daemon child invokes).
Iczelia::Handlers::Admin::Cache::run_rebuild($cfg);

is($db->one('SELECT COUNT(*) FROM response_cache'), 0,
  'response_cache cleared by rebuild');
is($db->one('SELECT rendered_html FROM pages WHERE slug=?', 'home'),
  undef, 'home rendered_html stays NULL (home re-renders per request)');

my $rendered = $db->all(
  q{SELECT slug, draft, rendered_html FROM posts ORDER BY slug});
for my $r (@$rendered) {
  if ($r->{draft}) {
    is($r->{rendered_html}, undef,
      "draft post '$r->{slug}' stays NULL");
  }
  else {
    ok(defined $r->{rendered_html} && length $r->{rendered_html} > 500,
      "published post '$r->{slug}' rendered_html populated");
    like($r->{rendered_html}, qr{$r->{slug}}, "rendered HTML mentions the slug");
  }
}

is(
  $db->setting('cache.rebuild.phase'),
  'done',
  'phase=done after successful rebuild'
);
ok($db->setting('cache.rebuild.finished_at') > 0,
  'finished_at recorded');
my $expected_total
  = $db->one('SELECT COUNT(*) FROM pages WHERE slug <> ?', 'home')
  + scalar(grep {!$_->{draft}} @$rendered);
is($db->setting('cache.rebuild.total'),
  $expected_total, 'total matches pages + published posts');
is($db->setting('cache.rebuild.done'),
  $expected_total, 'done counter reached total');
is($db->one('SELECT COUNT(*) FROM tex_cache'), 0,
  'scope=all leaves tex_cache empty (no math fragments seeded)');
ok(defined $db->setting('math.cache_stats'),
  'scope=all repopulates math stats snapshot via warmup');

# === scope=html: keep tex_cache, only re-render HTML ===
# Seed a tex_cache row to confirm it survives an HTML-only rebuild.
$db->do_(
  q{INSERT OR REPLACE INTO tex_cache(hash,display,html,created_at)
       VALUES('preserve',0,'<svg id="keep"/>',strftime('%s','now'))}
);
$db->do_(
  q{INSERT INTO response_cache(path,status,content_type,body,etag,created_at)
       VALUES('/another/',200,'text/html',CAST('y' AS BLOB),'def',
              strftime('%s','now'))}
);
$db->do_('UPDATE posts SET rendered_html = ? WHERE slug=?',
  'stale-body', 'first');

$db->set_setting('cache.rebuild.scope', 'html');
Iczelia::Handlers::Admin::Cache::run_rebuild($cfg);

is($db->one('SELECT html FROM tex_cache WHERE hash=?', 'preserve'),
  '<svg id="keep"/>', 'scope=html preserves tex_cache rows');
is($db->one('SELECT COUNT(*) FROM response_cache'), 0,
  'scope=html still clears response_cache');
ok(
  $db->one('SELECT rendered_html FROM posts WHERE slug=?', 'first') ne
    'stale-body',
  'scope=html re-rendered the post (rendered_html no longer the stale value)'
);
is($db->setting('cache.rebuild.scope'),
  'html', 'scope persisted through the rebuild');

# === warmer reports progress when progress_key is supplied ===
# Seed enough math fragments that the warmer pass actually does work,
# then call warmup with the progress hook and verify the counter
# advanced.
SKIP: {
  skip 'tex toolchain (latex/dvisvgm) not installed', 3
    unless _have_bin('latex') && _have_bin('dvisvgm');
  $db->do_('DELETE FROM tex_cache');
  $db->do_(
    q{INSERT INTO posts(kind, slug, title, date, body, updated_at)
         VALUES('blog','math','math post','2026-05-01',
                '# math: $a^2 + b^2 = c^2$ and $\\pi$',
                strftime('%s','now'))}
  );
  $db->set_setting('cache.rebuild.done',  0);
  $db->set_setting('cache.rebuild.total', 0);
  my $stderr = '';
  my $w2     = Iczelia::Warmer->new(cfg => $cfg, workers => 2);
  {
    local *STDERR;
    open STDERR, '>', \$stderr;
    $w2->warmup(
      progress_key => 'cache.rebuild.done',
      total_key    => 'cache.rebuild.total',
    );
  }
  ok($db->setting('cache.rebuild.total') > 0,
    'warmer published math total via total_key');
  is(
    $db->setting('cache.rebuild.done'),
    $db->setting('cache.rebuild.total'),
    'warmer progress counter reached total'
  );
  is(
    $db->one('SELECT COUNT(*) FROM tex_cache'),
    $db->setting('cache.rebuild.total'),
    'warmer actually populated tex_cache'
  );
}

sub _have_bin {
  my ($name) = @_;
  for my $d (split /:/, $ENV{PATH} // '') {
    return 1 if -x "$d/$name";
  }
  return 0;
}

# === warmer cooperates with an active rebuild ===
# Pretend a rebuild is in progress and ensure the supervisor's
# background pass (the one driven by Warmer::run) skips, instead of
# fighting the rebuild for SQLite write locks. We call _pass directly
# (no force=>1) since warmup intentionally bypasses the cooperate
# check.
$db->set_setting('cache.rebuild.phase', 'html');
$db->do_('DELETE FROM tex_cache');
my $w = Iczelia::Warmer->new(cfg => $cfg, workers => 1);

my $skipped_stderr = '';
{
  local *STDERR;
  open STDERR, '>', \$skipped_stderr;
  $w->_pass;
}
is($db->one('SELECT COUNT(*) FROM tex_cache'), 0,
  'background warmer pass skipped while rebuild phase is active');

# Idle phase: a background pass runs and does its work normally.
$db->set_setting('cache.rebuild.phase', 'done');
my $ran_stderr = '';
{
  local *STDERR;
  open STDERR, '>', \$ran_stderr;
  $w->_pass;
}
ok(defined $db->setting('math.cache_stats'),
  'warmer ran its pass once rebuild phase cleared');

# === cancel flow ===
# Spawn a long-running fake rebuild grandchild that publishes its own
# pid + pgid, then exercise _cache_rebuild_cancel and confirm the cancel
# endpoint sends SIGTERM to the right place and the handler runs.
my $started_at = time();
$db->set_setting('cache.rebuild.phase',       'html');
$db->set_setting('cache.rebuild.scope',       'all');
$db->set_setting('cache.rebuild.total',       1);
$db->set_setting('cache.rebuild.done',        0);
$db->set_setting('cache.rebuild.started_at',  $started_at);
$db->set_setting('cache.rebuild.finished_at', 0);
$db->set_setting('cache.rebuild.error',       '');
$db->set_setting('cache.rebuild.pid',         0);

require POSIX;
my $pid = fork();
if (!$pid) {
  POSIX::setsid();
  POSIX::setpgid(0, 0);
  $SIG{TERM} = sub {
    $SIG{TERM} = 'IGNORE';
    my $rdb = Iczelia::DB->connect($cfg);
    $rdb->set_setting('cache.rebuild.phase',       'cancelled');
    $rdb->set_setting('cache.rebuild.finished_at', time());
    $rdb->set_setting('cache.rebuild.pid',         0);
    $rdb->disconnect;
    POSIX::_exit(0);
  };
  my $sdb = Iczelia::DB->connect($cfg);
  $sdb->set_setting('cache.rebuild.pid', $$);
  $sdb->disconnect;
  sleep 30;
  POSIX::_exit(1);
}

# Wait for the child to publish its pid.
my $child_pid;
for (1 .. 50) {
  $child_pid = $db->setting('cache.rebuild.pid') + 0;
  last if $child_pid && $child_pid != 0;
  select(undef, undef, undef, 0.05);
}
ok($child_pid && $child_pid > 0, 'rebuild child published its pid');

# Build a fake ctx that _cache_rebuild_cancel will accept. The handler
# checks csrf via $ctx->{auth}, so install a stub that just says yes,
# and provide the gating context the helper expects.
require Iczelia::Context;
my $ctx = Iczelia::Context->new(
  db   => $db,
  auth => bless({}, 'CacheCancelStubAuth'),
);
{
  package CacheCancelStubAuth;
  sub require_csrf {return undef}
}
my $req = {
  method => 'POST', path => '/admin/cache/rebuild/cancel',
  params => {csrf => 'ignored'}, headers => {}, cookies => {},
  auth_sid => 'sid',
};

my $resp = Iczelia::Handlers::Admin::Cache::_cache_rebuild_cancel($ctx, $req);
is($resp->{status}, 303, 'cancel returns a redirect');

# waitpid blocks until the child's SIGTERM handler has finished its DB
# writes and called POSIX::_exit. Polling on a deadline raced under CI
# load (handler latency vs. wall-clock deadline).
waitpid($pid, 0);

is($db->setting('cache.rebuild.phase'),
  'cancelled', 'rebuild child set phase=cancelled on SIGTERM');
ok($db->setting('cache.rebuild.finished_at') >= $started_at,
  'finished_at recorded on cancel');
is($db->setting('cache.rebuild.pid'),
  0, 'pid cleared on cancel');

# Idempotency: cancel when no rebuild is running just redirects.
my $resp2 = Iczelia::Handlers::Admin::Cache::_cache_rebuild_cancel($ctx, $req);
is($resp2->{status}, 303, 'cancel-on-idle redirects without doing anything');

# === stale-pid recovery: process died without writing 'cancelled' ===
# Fork a child that exits immediately, leaving settings still pointing
# at its (now-reaped) pid. Cancel must detect the corpse and force-clear.
$db->set_setting('cache.rebuild.phase',       'html');
$db->set_setting('cache.rebuild.scope',       'all');
$db->set_setting('cache.rebuild.total',       10);
$db->set_setting('cache.rebuild.done',        3);
$db->set_setting('cache.rebuild.started_at',  time());
$db->set_setting('cache.rebuild.finished_at', 0);

my $dead_pid = fork();
if (!$dead_pid) {POSIX::_exit(0)}
waitpid($dead_pid, 0);

# Walk forward until the OS has actually freed the pid (kill 0 fails).
my $tries = 0;
while (kill(0, $dead_pid) && $tries++ < 20) {
  select(undef, undef, undef, 0.05);
}
$db->set_setting('cache.rebuild.pid', $dead_pid);

my $resp3 = Iczelia::Handlers::Admin::Cache::_cache_rebuild_cancel($ctx, $req);
is($resp3->{status}, 303, 'cancel returns redirect when pid is stale');
is($db->setting('cache.rebuild.phase'),
  'cancelled', 'stale pid is force-cleared to cancelled');
is($db->setting('cache.rebuild.pid'),
  0, 'pid cleared after stale force-clear');

# === second click on stuck cancelling escalates to KILL ===
# Stand up a child that ignores SIGTERM but accepts SIGKILL.
my $stubborn = fork();
if (!$stubborn) {
  POSIX::setsid();
  POSIX::setpgid(0, 0);
  $SIG{TERM} = 'IGNORE';
  my $sdb = Iczelia::DB->connect($cfg);
  $sdb->set_setting('cache.rebuild.pid', $$);
  $sdb->disconnect;
  sleep 30;
  POSIX::_exit(1);
}
my $stubborn_pid;
for (1 .. 50) {
  $stubborn_pid = $db->setting('cache.rebuild.pid') + 0;
  last if $stubborn_pid && $stubborn_pid != 0;
  select(undef, undef, undef, 0.05);
}
$db->set_setting('cache.rebuild.phase',       'html');
$db->set_setting('cache.rebuild.scope',       'all');
$db->set_setting('cache.rebuild.finished_at', 0);

# First click: TERM. The child ignores it, so the cancel handler
# just transitions phase to cancelling and leaves the pid alone.
Iczelia::Handlers::Admin::Cache::_cache_rebuild_cancel($ctx, $req);
is($db->setting('cache.rebuild.phase'),
  'cancelling', 'first click transitions to cancelling');
ok($db->setting('cache.rebuild.pid') == $stubborn_pid,
  'pid retained while we wait for the child to honour TERM');

# Second click: stubborn child still alive AND phase=cancelling.
# Endpoint must escalate to KILL and force-clear.
Iczelia::Handlers::Admin::Cache::_cache_rebuild_cancel($ctx, $req);
is($db->setting('cache.rebuild.phase'),
  'cancelled', 'second click force-clears phase=cancelled');
is($db->setting('cache.rebuild.pid'),
  0, 'pid cleared after force-clear');
my $reaped = waitpid($stubborn, 0);
is($reaped, $stubborn, 'stubborn child reaped after KILL');
ok(POSIX::WIFSIGNALED(${^CHILD_ERROR_NATIVE}),
  'stubborn child exited via signal (SIGKILL)');
is(POSIX::WTERMSIG(${^CHILD_ERROR_NATIVE}),
  POSIX::SIGKILL(), 'signal was SIGKILL');

done_testing;
