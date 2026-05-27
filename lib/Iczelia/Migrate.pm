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
# New tables/indices are defined in share/schema.sql under the
# CREATE ... IF NOT EXISTS guards; fresh installs pick those up. A
# restart-only upgrade does not re-run the schema file, so anything a
# running daemon needs (new tables, added or renamed columns) also gets
# an idempotent migration here.
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
  # 0.1.3 -> 0.1.4: static subpages (uploaded HTML/CSS/JS bundles).
  {
    version => '0.1.3 -> 0.1.4',
    name    => 'subpages + subpage_files tables',
    check   => sub {_table_exists($_[0], 'subpages')},
    apply   => sub {
      my ($db) = @_;
      $db->dbh->do(
        q{CREATE TABLE IF NOT EXISTS subpages (
            id         INTEGER PRIMARY KEY,
            slug       TEXT    NOT NULL UNIQUE,
            title      TEXT    NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )}
      );
      $db->dbh->do(
        q{CREATE TABLE IF NOT EXISTS subpage_files (
            id           INTEGER PRIMARY KEY,
            subpage_id   INTEGER NOT NULL
                         REFERENCES subpages(id) ON DELETE CASCADE,
            path         TEXT    NOT NULL,
            content      BLOB    NOT NULL,
            content_type TEXT    NOT NULL,
            size         INTEGER NOT NULL,
            is_binary    INTEGER NOT NULL DEFAULT 0,
            updated_at   INTEGER NOT NULL,
            UNIQUE (subpage_id, path)
          )}
      );
      $db->dbh->do('CREATE INDEX IF NOT EXISTS subpage_files_pid'
        . ' ON subpage_files(subpage_id)');
    },
  },

  # 0.1.4 -> 0.1.5: subpages.listing toggle for Apache-style indexes.
  {
    version => '0.1.4 -> 0.1.5',
    name    => 'subpages.listing column',
    check   => sub {_has_column($_[0], 'subpages', 'listing')},
    apply   => sub {
      $_[0]->dbh->do(
        q{ALTER TABLE subpages
            ADD COLUMN listing INTEGER NOT NULL DEFAULT 0});
    },
  },

  # 0.1.5 -> 0.1.6: resumable upload sessions for large admin uploads.
  {
    version => '0.1.5 -> 0.1.6',
    name    => 'upload_sessions table',
    check   => sub {_table_exists($_[0], 'upload_sessions')},
    apply   => sub {
      my ($db) = @_;
      $db->dbh->do(
        q{CREATE TABLE IF NOT EXISTS upload_sessions (
            id           TEXT    PRIMARY KEY,
            sid          TEXT    NOT NULL,
            filename     TEXT,
            size         INTEGER NOT NULL DEFAULT 0,
            created_at   INTEGER NOT NULL,
            finalized_at INTEGER
          )}
      );
      $db->dbh->do(
        'CREATE INDEX IF NOT EXISTS upload_sessions_created'
        . ' ON upload_sessions(created_at)'
      );
    },
  },

  # 0.1.5 -> 0.1.6: AI slop bot trap cache.
  {
    version => '0.1.5 -> 0.1.6',
    name    => 'slop_pages table',
    check   => sub {_table_exists($_[0], 'slop_pages')},
    apply   => sub {
      $_[0]->dbh->do(
        q{CREATE TABLE IF NOT EXISTS slop_pages (
            path       TEXT PRIMARY KEY,
            body       TEXT NOT NULL,
            created_at INTEGER NOT NULL
          )}
      );
    },
  },

  # 0.1.5 -> 0.1.6: cgit-style git repos.
  {
    version => '0.1.5 -> 0.1.6',
    name    => 'git_repos + git_commit_cache tables',
    check   => sub {_table_exists($_[0], 'git_repos')},
    apply   => sub {
      my ($db) = @_;
      $db->dbh->do(
        q{CREATE TABLE IF NOT EXISTS git_repos (
            id                INTEGER PRIMARY KEY,
            slug              TEXT    NOT NULL UNIQUE,
            title             TEXT    NOT NULL DEFAULT '',
            owner             TEXT    NOT NULL DEFAULT '',
            description       TEXT    NOT NULL DEFAULT '',
            default_branch    TEXT    NOT NULL DEFAULT 'main',
            mirror_url        TEXT,
            mirror_interval_s INTEGER NOT NULL DEFAULT 3600,
            last_pulled_at    INTEGER,
            last_pull_status  TEXT,
            last_pull_error   TEXT,
            head_sha          TEXT,
            created_at        INTEGER NOT NULL,
            updated_at        INTEGER NOT NULL
          )}
      );
      $db->dbh->do(
        q{CREATE INDEX IF NOT EXISTS git_repos_mirror_due
            ON git_repos(last_pulled_at) WHERE mirror_url IS NOT NULL}
      );
      $db->dbh->do(
        q{CREATE TABLE IF NOT EXISTS git_commit_cache (
            repo_id        INTEGER NOT NULL
                            REFERENCES git_repos(id) ON DELETE CASCADE,
            head_sha       TEXT    NOT NULL,
            dir            TEXT    NOT NULL,
            name           TEXT    NOT NULL,
            commit_sha     TEXT    NOT NULL,
            commit_subject TEXT    NOT NULL,
            commit_at      INTEGER NOT NULL,
            PRIMARY KEY (repo_id, head_sha, dir, name)
          )}
      );
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
