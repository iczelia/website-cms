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

# cache_control/vary hold what the handler served the miss with. They
# are nullable on purpose: rows from the previous build keep serving
# under the path-derived policy, so an upgrade never drops the cache.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Cache;
use Iczelia::Migrate;
use Iczelia::CachePolicy;

my $tmp = File::Temp->newdir;

# Pre-migration shape: schema.sql minus the new columns.
my $db = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->dbh->do('ALTER TABLE response_cache DROP COLUMN cache_control');
$db->dbh->do('ALTER TABLE response_cache DROP COLUMN vary');

sub has_col {
  $db->one(q{SELECT 1 FROM pragma_table_info('response_cache')
               WHERE name=? LIMIT 1}, $_[0]) ? 1 : 0;
}

ok(!has_col('cache_control'), 'cache_control absent before migrate');
ok(!has_col('vary'),          'vary absent before migrate');

# A row the previous build cached, with nowhere to record policy.
$db->do_(
  q{INSERT INTO response_cache(path,status,content_type,body,etag,created_at)
      VALUES('/blog/',200,'text/html; charset=utf-8','<p>old</p>','deadbeef',0)}
);

is(Iczelia::Migrate::run($db), 1, 'one migration applied');
ok(has_col('cache_control'), 'cache_control created');
ok(has_col('vary'),          'vary created');

is(Iczelia::Migrate::run($db), 0, 'rerun is a no-op');
is(Iczelia::Migrate::run($db), 0, 'and stays a no-op');

my $cache = Iczelia::Cache->new(db => $db, compress => 0);
my $hit   = $cache->get('/blog/', {headers => {}});
ok($hit, 'row cached before the migration still serves');
is($hit->{body}, '<p>old</p>', 'with its original body');
is($hit->{headers}{'Cache-Control'},
  Iczelia::CachePolicy::cache_control_for('/blog/'),
  'NULL cache_control falls back to the path policy it was stored under');
is($hit->{headers}{Vary}, 'Accept-Encoding',
  'NULL vary falls back to the fixed stamp it was stored under');

# The check keys on cache_control, so a crash between the two ALTERs
# must not strand vary.
my $partial = Iczelia::DB->connect("$tmp/partial.db");
$partial->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$partial->dbh->do('ALTER TABLE response_cache DROP COLUMN cache_control');
is(Iczelia::Migrate::run($partial), 1, 'partial upgrade migrates');
ok(
  $partial->one(q{SELECT 1 FROM pragma_table_info('response_cache')
                    WHERE name='cache_control'}),
  'and adds only the missing column'
);

my $fresh = Iczelia::DB->connect("$tmp/fresh.db");
$fresh->apply_schema_file("$FindBin::Bin/../share/schema.sql");
is(Iczelia::Migrate::run($fresh), 0, 'schema.sql ships the columns already');

done_testing;
