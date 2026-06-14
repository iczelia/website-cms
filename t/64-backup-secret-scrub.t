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

# A backup snapshot must not carry key material or instance-bound rows:
# the auth secret and ephemeral tables are scrubbed, ordinary settings
# are preserved.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use DBI ();
use Iczelia::Handlers::Backup;

my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/site.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

# Seed: a normal setting, a lingering auth secret, an ephemeral cache row.
$db->set_setting('site.title',         'Hello');
$db->set_setting('auth.cookie_secret', 'deadbeef' x 8);
$db->do_(
  q{INSERT INTO response_cache(path, status, content_type, body, etag, created_at)
            VALUES('/x', 200, 'text/plain', 'j', 'e', strftime('%s','now'))}
);

# Snapshot exactly as _export does, then run the real scrub.
my $snap = "$tmp/snap.db";
$db->dbh->do(q{VACUUM INTO ?}, undef, $snap);
my $sdbh = DBI->connect("dbi:SQLite:dbname=$snap", '', '',
  {RaiseError => 1, PrintError => 0});
Iczelia::Handlers::Backup::_scrub_snapshot($sdbh);

is(
  $sdbh->selectrow_array(
    q{SELECT value FROM settings WHERE key = 'auth.cookie_secret'}),
  undef,
  'auth secret scrubbed from the snapshot'
);
is(
  $sdbh->selectrow_array(
    q{SELECT value FROM settings WHERE key = 'site.title'}),
  'Hello',
  'ordinary settings preserved'
);
is($sdbh->selectrow_array(q{SELECT COUNT(*) FROM response_cache}),
  0, 'ephemeral response_cache scrubbed');

$sdbh->disconnect;
done_testing;
