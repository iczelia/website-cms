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
use Iczelia::Content;

package R;
sub new             {bless {}, shift}
sub invalidate_post { }
sub invalidate_page { }
sub invalidate_home { }
sub invalidate_all  { }

package main;

# Skip if `tar` isn't present.
my $have_tar = 0;
for my $d (split /:/, ($ENV{PATH} || '/usr/bin')) {
  if (-x "$d/tar") {$have_tar = 1; last}
}
plan skip_all => 'tar not in PATH' unless $have_tar;

my $tmpdir = File::Temp->newdir;
my $src_db = "$tmpdir/src.db";
my $tgt_db = "$tmpdir/tgt.db";

# 1. Build source DB and seed it.
my $sdb = Iczelia::DB->connect($src_db);
$sdb->apply_schema_file("$FindBin::Bin/../share/schema.sql");
my $sc = Iczelia::Content->new(db => $sdb, render => R->new);
$sc->create_post('blog',
  {title => 'one', body => 'first', date => '2026-05-09'});
$sc->create_post('blog',
  {title => 'two', body => 'second', date => '2026-05-09'});

# Add a bogus row to response_cache to confirm export strips it.
$sdb->do_(
  q{INSERT INTO response_cache(path, status, content_type, body, etag, created_at)
            VALUES('/x', 200, 'text/plain', ?, 'e', strftime('%s','now'))},
  "junk"
);
ok($sdb->one('SELECT COUNT(*) FROM response_cache') >= 1,
  'response_cache populated in source');

# 2. Snapshot via VACUUM INTO + strip ephemeral tables (mirrors what
# the backup handler does internally).
my $snap = "$tmpdir/snap.db";
$sdb->dbh->do(q{VACUUM INTO ?}, undef, $snap);
my $snap_dbh = DBI->connect("dbi:SQLite:dbname=$snap", '', '',
  {RaiseError => 1, PrintError => 0});
$snap_dbh->do("DELETE FROM response_cache");
$snap_dbh->do("DELETE FROM tex_cache");
$snap_dbh->do("DELETE FROM sessions");
$snap_dbh->disconnect;

# 3. Open the snapshot as the target and verify content round-trips,
# but without ephemeral rows.
my $tdb    = Iczelia::DB->connect($snap);
my $tposts = $tdb->all('SELECT slug, title, body FROM posts ORDER BY slug');
is(scalar(@$tposts),    2,     'two posts in snapshot');
is($tposts->[0]{title}, 'one', 'title roundtrip');
is($tdb->one('SELECT COUNT(*) FROM response_cache'),
  0, 'response_cache stripped from snapshot');

done_testing;
