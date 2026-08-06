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

package Iczelia::Git::Mirrors;
use strict;
use warnings;
use File::Path  qw(make_path);
use Fcntl       qw(:flock O_WRONLY O_CREAT);
use Iczelia::Git ();
use Iczelia::Cache ();

# Periodic mirror puller invoked from the warmer's _pass(). Selects
# repos that are past their per-repo interval, takes a non-blocking
# flock so it never overlaps with a manual pull from the admin panel,
# and refreshes the on-disk bare repo. On any HEAD movement, busts the
# /git/<slug>/ response-cache prefix and the global /git/ index page,
# and drops stale per-HEAD rows from git_commit_cache.

# ssh options for clone_mirror / pull_mirror, from config. known_hosts
# defaults into var/git/ so an accept-new first contact survives a
# restart.
sub ssh_opts {
  my ($cfg, $var_dir) = @_;
  $cfg ||= {};
  my $known = $cfg->{'git-ssh-known-hosts'};
  $known = "$var_dir/git/known_hosts"
    if (!defined $known || !length $known) && defined $var_dir;
  return {
    key         => $cfg->{'git-ssh-key'},
    known_hosts => $known,
    strict      => $cfg->{'git-ssh-strict'},
  };
}

sub pump {
  my (%arg) = @_;
  my $db      = $arg{db}      or die "db required";
  my $var_dir = $arg{var_dir} or die "var_dir required";
  my $on_log  = $arg{on_log}  || sub { warn "[git mirrors] $_[0]\n" };
  my $max     = $arg{max_jobs} // 4;
  my $ssh     = $arg{ssh} || ssh_opts($arg{cfg}, $var_dir);

  return 0 unless Iczelia::Git::available();

  my $now  = time;
  # CAST(? AS INTEGER): DBD::SQLite binds Perl scalars as TEXT, so a
  # bare comparison falls into lexical-string land and "1779747619"
  # comes BEFORE "1779657619" -- which would mark every future-dated
  # mirror as "due" forever. Explicit cast forces numeric compare.
  my $due  = $db->all(
    q{SELECT id, slug, mirror_url, mirror_interval_s, last_pulled_at, head_sha
        FROM git_repos
       WHERE mirror_url IS NOT NULL
         AND (last_pulled_at IS NULL
              OR last_pulled_at + mirror_interval_s
                 <= CAST(? AS INTEGER))
       ORDER BY COALESCE(last_pulled_at, 0) ASC
       LIMIT ?}, $now, $max
  );
  return 0 unless $due && @$due;

  my $cache = eval { Iczelia::Cache->new(db => $db) };
  my $done  = 0;
  for my $row (@$due) {
    my $path = eval { Iczelia::Git::bare_repo_path($var_dir, $row->{slug}) };
    if (!defined $path) {
      $on_log->("$row->{slug}: invalid slug, skipping");
      next;
    }
    make_path($var_dir . '/git');

    # Per-repo flock: a manual admin pull holds the same lock, so we
    # never let two libgit2 fetches race on the same on-disk repo.
    my $lockfile = "$var_dir/git/$row->{slug}.lock";
    open my $lock, '>', $lockfile or do {
      $on_log->("$row->{slug}: cannot open lock: $!");
      next;
    };
    unless (flock($lock, LOCK_EX | LOCK_NB)) {
      close $lock;
      next;
    }

    my ($ok, $err, $new_head);
    if (-d "$path/objects") {
      ($ok, $err, $new_head) = Iczelia::Git::pull_mirror($path, ssh => $ssh);
    }
    else {
      ($ok, $err, $new_head) = eval {
        Iczelia::Git::clone_mirror($path, $row->{mirror_url}, ssh => $ssh);
      };
      $err = $@ unless defined $ok;
    }

    if ($ok) {
      $db->do_(
        q{UPDATE git_repos
             SET last_pulled_at = ?, last_pull_status = 'ok',
                 last_pull_error = NULL, head_sha = ?, updated_at = ?
           WHERE id = ?}, $now, $new_head, $now, $row->{id}
      );
      if (defined $new_head
        && (!defined $row->{head_sha} || $new_head ne $row->{head_sha}))
      {
        if ($cache) {
          $cache->bust_prefix("/git/$row->{slug}/");
          $cache->bust('/git/');
        }
        $db->do_(
          q{DELETE FROM git_commit_cache
             WHERE repo_id = ? AND head_sha != ?}, $row->{id}, $new_head
        );
      }
      $on_log->("$row->{slug}: pulled head=" . ($new_head // 'none'));
    }
    else {
      my $emsg = (defined $err ? "$err" : 'unknown error');
      $emsg =~ s/\s+\z//;
      $db->do_(
        q{UPDATE git_repos
             SET last_pulled_at = ?, last_pull_status = 'error',
                 last_pull_error = ?, updated_at = ?
           WHERE id = ?}, $now, substr($emsg, 0, 1024), $now, $row->{id}
      );
      $on_log->("$row->{slug}: pull error: $emsg");
    }

    flock($lock, LOCK_UN);
    close $lock;
    $done++;
  }
  return $done;
}

1;
