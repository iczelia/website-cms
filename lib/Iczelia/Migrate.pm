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

package Iczelia::Migrate;
use strict;
use warnings;

# Idempotent schema migrations.
#
# Wholly-new tables/indices land in share/schema.sql under the
# CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS guards;
# fresh installs pick those up automatically. This module handles the
# OTHER half: ALTER-shape changes (added columns, renamed columns)
# that pre-existing tables need patched in on upgrade.
#
# Each migration record carries:
#   version  the release pair it bridges, e.g. '0.1.0 -> 0.1.1'.
#            Annotation only; the run order is the array order.
#   name     short human label written to the log on apply.
#   check    coderef returning true when the migration is already
#            applied (or doesn't apply to this DB shape).
#   apply    coderef that performs the change. Called only when check
#            returned false.
#
# Re-running run() is a no-op. Two daemons racing on the same ALTER
# are tolerated: the loser re-runs `check`, sees the change in place,
# and counts the step as applied.
#
# Hooked in two places:
#   * bin/iczelia-init after apply_schema_file (the fresh-install
#     path also lands here so init logs are explicit).
#   * Iczelia::App::build right after Iczelia::DB->connect (the
#     daemon's safety net for `podman pull && systemctl restart`
#     without a manual init step).
#
# Usage:
#   Iczelia::Migrate::run($db);

my @MIGRATIONS = (

  # 0.1.0 -> 0.1.1: post series. Adds the `series_id` and
  # `series_position` columns to the existing `posts` table. The
  # `series` table itself and the `posts_series` index are created by
  # CREATE TABLE/INDEX IF NOT EXISTS in schema.sql.
  {
    version => '0.1.0 -> 0.1.1',
    name    => 'posts.series_id + series_position',
    check   =>
      sub {_has_column($_[0], 'posts', 'series_id')},
    apply => sub {
      my ($db) = @_;
      $db->dbh->do('ALTER TABLE posts ADD COLUMN series_id INTEGER');
      $db->dbh->do(
        'ALTER TABLE posts ADD COLUMN series_position INTEGER');
    },
  },

  # 0.1.1 -> 0.1.2: UA breakdown. Adds derived browser/os/device and a
  # raw bot UA column to analytics_events. The analytics_ua roll-up
  # table is created by CREATE TABLE IF NOT EXISTS in schema.sql.
  {
    version => '0.1.1 -> 0.1.2',
    name    => 'analytics_events.browser/os/device/bot_ua',
    check   =>
      sub {_has_column($_[0], 'analytics_events', 'browser')},
    apply => sub {
      my ($db) = @_;
      $db->dbh->do('ALTER TABLE analytics_events ADD COLUMN browser TEXT');
      $db->dbh->do('ALTER TABLE analytics_events ADD COLUMN os TEXT');
      $db->dbh->do('ALTER TABLE analytics_events ADD COLUMN device TEXT');
      $db->dbh->do('ALTER TABLE analytics_events ADD COLUMN bot_ua TEXT');
    },
  },
);

sub run {
  my ($db) = @_;

  # Fresh DB whose schema hasn't been applied yet (no `posts` table):
  # nothing to migrate. The caller (iczelia-init / App::build) applies
  # schema.sql separately, after which a subsequent run() finds the
  # right shape already in place.
  return 0 unless _table_exists($db, 'posts');

  my $applied = 0;
  for my $m (@MIGRATIONS) {
    next if $m->{check}->($db);
    my $ok = eval {$m->{apply}->($db); 1};
    if (!$ok) {
      my $err = $@ || 'unknown error';

      # Two starts racing on the same ALTER: one wins, the other sees a
      # "duplicate column" / similar error. If the check now passes,
      # the migration completed under us; treat that as success.
      if ($m->{check}->($db)) {
        print STDERR
          "[migrate] applied (raced) [$m->{version}]: $m->{name}\n";
        $applied++;
        next;
      }
      die "migration '$m->{name}' [$m->{version}] failed: $err";
    }
    print STDERR "[migrate] applied [$m->{version}]: $m->{name}\n";
    $applied++;
  }
  return $applied;
}

# True when the named column exists on the table; we use SQLite's
# pragma_table_info virtual table so the query is portable and cheap.
sub _has_column {
  my ($db, $table, $column) = @_;
  my $r = $db->one(
    q{SELECT 1 FROM pragma_table_info(?) WHERE name = ? LIMIT 1},
    $table, $column
  );
  return $r ? 1 : 0;
}

# True when the named user table exists (sqlite_master entry).
sub _table_exists {
  my ($db, $table) = @_;
  my $r = $db->one(
    q{SELECT 1 FROM sqlite_master
       WHERE type = 'table' AND name = ? LIMIT 1}, $table
  );
  return $r ? 1 : 0;
}

1;
