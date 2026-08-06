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

# Backup restore must replace live content from a snapshot WITHOUT
# corrupting the db. The old code swapped the db file out from under the
# live preforked workers and left stale -wal/-shm sidecars, which SQLite
# mis-applied to the new file -> "database disk image is malformed". The
# replacement copies tables in place inside one deferred-FK transaction.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Content;
use Iczelia::Handlers::Backup;

package R;
sub new             { bless {}, shift }
sub invalidate_post { }
sub invalidate_page { }
sub invalidate_home { }
sub invalidate_all  { }
package main;

my $tmp = File::Temp->newdir;

# Live db: one post ("OLD") plus a row in an ephemeral cache table.
my $live = Iczelia::DB->connect("$tmp/live.db");
$live->apply_schema_file("$FindBin::Bin/../share/schema.sql");
Iczelia::Content->new(db => $live, render => R->new)
  ->create_post('blog', {title => 'OLD', body => 'old', date => '2026-01-01'});
$live->do_(
  q{INSERT INTO response_cache(path,status,content_type,body,etag,created_at)
            VALUES('/stale',200,'text/plain','x','e',1)});
ok($live->one('SELECT COUNT(*) FROM response_cache') >= 1, 'live has a cache row');

# Snapshot db: two different posts; ephemeral tables empty (as exported).
my $snap = "$tmp/snap.db";
my $sdb  = Iczelia::DB->connect($snap);
$sdb->apply_schema_file("$FindBin::Bin/../share/schema.sql");
my $sc = Iczelia::Content->new(db => $sdb, render => R->new);
$sc->create_post('blog', {title => 'NEW1', body => 'a', date => '2026-02-01'});
$sc->create_post('blog', {title => 'NEW2', body => 'b', date => '2026-02-02'});
$sdb->disconnect;

# In-place restore (the operation that used to corrupt via file swap).
Iczelia::Handlers::Backup::_restore_from_snapshot($live, $snap);

# Content replaced, not appended.
my $titles = $live->all('SELECT title FROM posts ORDER BY title');
is_deeply([map { $_->{title} } @$titles], ['NEW1', 'NEW2'],
  'live content replaced by the snapshot');

# The whole point: no corruption.
is($live->one('PRAGMA integrity_check'), 'ok',
  'live db integrity ok after in-place restore');

# Deferred FK worked: post_revisions sorts before posts, so it is inserted
# while its parent rows do not yet exist; the commit must still hold.
is(
  $live->one(q{SELECT COUNT(*) FROM post_revisions r
                 LEFT JOIN posts p ON p.id = r.post_id
                WHERE p.id IS NULL}),
  0, 'no dangling post_revisions FK after restore'
);

# Ephemeral table replaced with the snapshot's empty copy.
is($live->one('SELECT COUNT(*) FROM response_cache'), 0,
  'stale cache cleared by restore');

# A fresh connection sees a clean, populated db (no stale-WAL artifact).
my $fresh = Iczelia::DB->connect("$tmp/live.db");
is($fresh->one('PRAGMA integrity_check'), 'ok',
  'fresh connection: db still ok');
is($fresh->one('SELECT COUNT(*) FROM posts'), 2, 'fresh connection: 2 posts');

# Archive guard: a safe archive passes; an unsafe path is named distinctly
# (not the old blanket "unsafe paths" for every failure).
{
  require Archive::Tar;
  my $safe = Archive::Tar->new;
  $safe->add_data('site.db',     'x');
  $safe->add_data('media/a.png', 'y');
  $safe->write("$tmp/safe.tar");
  is(Iczelia::Handlers::Backup::_archive_problem("$tmp/safe.tar"),
    undef, 'safe archive: no problem');

  my $evil = Archive::Tar->new;
  $evil->add_data('../escape', 'x');
  $evil->write("$tmp/evil.tar");
  like(Iczelia::Handlers::Backup::_archive_problem("$tmp/evil.tar"),
    qr/unsafe path/, 'traversal path: reported as unsafe path');
}

# Media swap replaces dst contents atomically and leaves no stale files.
{
  my $md  = File::Temp->newdir;
  my $src = "$md/src";
  my $dst = "$md/dst";
  mkdir $src;
  mkdir $dst;
  open my $a, '>', "$src/new.bin" or die $!; print {$a} 'new'; close $a;
  open my $b, '>', "$dst/old.bin" or die $!; print {$b} 'old'; close $b;
  is(Iczelia::Handlers::Backup::_swap_media_dir($src, $dst),
    undef, 'media swap succeeds');
  ok(-f "$dst/new.bin",  'swapped-in media present');
  ok(!-e "$dst/old.bin", 'stale media removed');
  ok(!-e "$dst.incoming.$$" && !-e "$dst.old.$$", 'no staging dirs left behind');
}

done_testing;
