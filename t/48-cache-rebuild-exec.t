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

# Regression test for the libsqlite-after-fork hazard. The admin
# rebuild path runs from a request worker that has an open DBD::SQLite
# handle. Forking and then calling Iczelia::DB->connect inside the
# child aborts the process via libsqlite assertion -- no Perl
# exception, just SIGABRT.
#
# The fix is to exec() into a clean perl. This test reproduces the
# unsafe shape (parent holds an open DB handle, then fork+exec) and
# verifies the helper runs to completion and updates the rebuild state.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use POSIX      ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;

my $tmpdir = File::Temp->newdir;
my $dbpath = "$tmpdir/test.db";
my $sharedir = "$FindBin::Bin/../share";
my $tmpsub   = "$tmpdir/tmp";
my $mediasub = "$tmpdir/media";
mkdir $tmpsub;
mkdir $mediasub;

my $config_path = "$tmpdir/iczelia.conf";
open my $cfh, '>', $config_path or die "open conf: $!";
print $cfh <<"CFG";
listen-tcp = 127.0.0.1:0
db = $dbpath
share-dir = $sharedir
chrome-dir = $sharedir/chrome
tmp-dir = $tmpsub
media-dir = $mediasub
CFG
close $cfh;

my $db = Iczelia::DB->connect($dbpath);
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->apply_schema_file("$FindBin::Bin/../share/seed.sql");

# Seed one published post so the html phase has something to render.
$db->do_(
  q{INSERT INTO posts(kind, slug, title, date, body, updated_at)
       VALUES('blog','sentinel','sentinel','2026-05-01','# body',
              strftime('%s','now'))}
);

# Mimic the admin worker: set initial state, then fork+exec the helper
# while THIS process still has $db open. That's the dangerous shape.
$db->set_setting('cache.rebuild.phase',       'starting');
$db->set_setting('cache.rebuild.scope',       'html');
$db->set_setting('cache.rebuild.started_at',  time());
$db->set_setting('cache.rebuild.finished_at', 0);
$db->set_setting('cache.rebuild.error',       '');
$db->set_setting('cache.rebuild.pid',         0);
$db->set_setting('cache.rebuild.total',       0);
$db->set_setting('cache.rebuild.done',        0);

my $helper = "$FindBin::Bin/../bin/iczelia-rebuild-cache";
ok(-x $helper, 'helper binary is executable');

my $pid = fork();
die "fork: $!" unless defined $pid;
if ($pid == 0) {
  POSIX::setsid();
  my $pid2 = fork();
  POSIX::_exit(0) if !defined $pid2 || $pid2 != 0;

  open STDIN,  '<',  '/dev/null';
  open STDOUT, '>>', '/dev/null';
  open STDERR, '>>', '/dev/null';
  for my $fd (3 .. 255) {eval {POSIX::close($fd)}}

  {exec($^X, "-I$FindBin::Bin/../lib", $helper, '--config', $config_path)}
  POSIX::_exit(127);
}
waitpid($pid, 0);

# Poll for completion. The helper is detached; we read fresh state
# from a fresh DBI connection so we don't have to wait on any IPC.
my $deadline = time() + 60;
my $state;
while (time() < $deadline) {
  my $r = Iczelia::DB->connect($dbpath);
  $state = {
    phase       => $r->setting('cache.rebuild.phase') // '',
    pid         => $r->setting('cache.rebuild.pid') // 0,
    total       => $r->setting('cache.rebuild.total') // 0,
    done        => $r->setting('cache.rebuild.done') // 0,
    finished_at => $r->setting('cache.rebuild.finished_at') // 0,
    error       => $r->setting('cache.rebuild.error') // '',
  };
  $r->disconnect;
  last if $state->{phase} eq 'done' || $state->{phase} eq 'error';
  select(undef, undef, undef, 0.2);
}

is($state->{phase}, 'done',
  'rebuild helper reached phase=done across the fork+exec boundary');
is($state->{error},
  '', 'no error written (libsqlite-after-fork no longer aborts us)');
ok($state->{finished_at} > 0, 'finished_at recorded');
is($state->{pid}, 0, 'pid cleared on completion');
ok($state->{done} == $state->{total} && $state->{total} > 0,
  'done counter reached total');

# Confirm the rendered_html row actually got written, i.e. the helper
# really did do the work (not just flip the phase setting).
ok(defined
    $db->one('SELECT rendered_html FROM posts WHERE slug=?', 'sentinel'),
  'sentinel post got rendered_html populated by the helper'
);

done_testing;
