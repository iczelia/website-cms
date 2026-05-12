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

package Iczelia::SelfUpdate;
use strict;
use warnings;
use Iczelia          ();
use Iczelia::Process ();

# In-place git self-updater. Fetches the configured branch (default
# `release` on `origin`), reads its Iczelia $VERSION, and -- only when
# the difference is a forward patch-level bump on the same major.minor
# (x.y.Z with Z increased and x, y unchanged) and the working tree is
# clean -- fast-forwards the checkout to it. Anything wider (a
# minor/major bump, a downgrade, a dirty tree, diverged history) is
# reported and left for a human.
#
# git is shelled out to so we don't grow a dependency; a custom `git`
# path can be injected for tests. Cron-driven via bin/iczelia-update.

sub new {
  my ($class, %arg) = @_;
  my $self = {
    repo_dir    => $arg{repo_dir} || _repo_root(),
    remote      => defined $arg{remote} ? $arg{remote} : 'origin',
    branch      => $arg{branch}  || 'release',
    git         => $arg{git}     || 'git',
    timeout     => $arg{timeout} || 30,
    current     => defined $arg{current} ? $arg{current} : $Iczelia::VERSION,
    restart_cmd => $arg{restart_cmd},    # string passed to `sh -c`, optional
  };
  bless $self, $class;
}

sub _repo_root {
  require FindBin;
  require File::Spec;
  no warnings 'once';
  return File::Spec->rel2abs("$FindBin::RealBin/..");
}

# The ref we compare against. With a remote configured it's the
# remote-tracking branch (after a fetch); otherwise a plain local
# branch and no fetch is done.
sub _target_ref {
  my ($self) = @_;
  return length $self->{remote}
    ? "$self->{remote}/$self->{branch}"
    : $self->{branch};
}

# Run `git -C <repo> @args`; returns stdout on success (possibly the
# empty string), undef on any failure (non-zero exit, timeout, missing
# binary).
sub _git {
  my ($self, @args) = @_;
  return Iczelia::Process::run_capped(
    [$self->{git}, '-C', $self->{repo_dir}, @args],
    timeout => $self->{timeout},
  );
}

# Parse "x.y.z" into [x, y, z]; undef on anything else. A trailing
# "-dev"/"+meta" etc. is rejected on purpose -- we only chase clean
# releases.
sub _parse_version {
  my ($v) = @_;
  return undef
    unless defined $v && $v =~ /\A([0-9]+)\.([0-9]+)\.([0-9]+)\z/;
  return [$1 + 0, $2 + 0, $3 + 0];
}

sub _cmp_version {
  my ($a, $b) = @_;
  return $a->[0] <=> $b->[0]
    || $a->[1] <=> $b->[1]
    || $a->[2] <=> $b->[2];
}

# Inspect remote vs. current without touching the working tree.
# Returns a hashref:
#   action         => 'update' | 'noop' | 'skip' | 'error'
#   reason         => human-readable line
#   current        => running version
#   remote_ref     => ref examined
#   remote_version => version found there (when readable)
sub check {
  my ($self) = @_;
  my $ref = $self->_target_ref;
  my %out = (current => $self->{current}, remote_ref => $ref);

  my $cur = _parse_version($self->{current});
  return {%out, action => 'error',
    reason => "unparseable current version '$self->{current}'"}
    unless $cur;

  return {%out, action => 'error',
    reason => "$self->{repo_dir} is not a git checkout"}
    unless defined $self->_git('rev-parse', '--git-dir');

  if (length $self->{remote}) {
    return {%out, action => 'error',
      reason => "git fetch $self->{remote} $self->{branch} failed"}
      unless defined
      $self->_git('fetch', '--quiet', $self->{remote}, $self->{branch});
  }

  my $blob = $self->_git('show', "$ref:lib/Iczelia.pm");
  return {%out, action => 'error',
    reason => "cannot read lib/Iczelia.pm at $ref (no such branch?)"}
    unless defined $blob;

  my ($rv) = $blob =~ /\$VERSION\s*=\s*['"]([^'"]+)['"]/;
  $out{remote_version} = $rv if defined $rv;
  my $rem = _parse_version($rv);
  return {%out, action => 'error',
    reason => "unparseable version at $ref: "
      . (defined $rv ? "'$rv'" : '(none found)')}
    unless $rem;

  my $delta = _cmp_version($rem, $cur);
  return {%out, action => 'noop', reason => "already at $rv"}
    if $delta == 0;
  return {%out, action => 'skip',
    reason => "$ref is $rv, older than $self->{current}; refusing to downgrade"}
    if $delta < 0;
  return {%out, action => 'skip',
    reason => "$self->{current} -> $rv is not a patch-level bump; update manually"}
    if $rem->[0] != $cur->[0] || $rem->[1] != $cur->[1];

  # major.minor unchanged, patch increased: eligible. Refuse if the
  # working tree has tracked modifications -- a fast-forward would
  # fail or clobber them.
  my $dirty = $self->_git('status', '--porcelain', '--untracked-files=no');
  return {%out, action => 'error', reason => 'git status failed'}
    unless defined $dirty;
  return {%out, action => 'skip',
    reason => 'working tree has local changes; update manually'}
    if length $dirty;

  return {%out, action => 'update',
    reason => "patch update $self->{current} -> $rv"};
}

# Fast-forward the checkout to the target ref. Returns ($ok, $message).
sub _fast_forward {
  my ($self) = @_;
  my $ref = $self->_target_ref;
  return (1, undef) if defined $self->_git('merge', '--ff-only', $ref);
  return (0, "fast-forward to $ref failed (diverged history?)");
}

# check(), then -- unless dry_run -- fast-forward and run the restart
# command. Returns the check() hashref, with action rewritten to
# 'updated' on success and 'error' if the fast-forward failed, plus
# (when a restart command is configured) restarted => 0|1 and, on
# failure, restart_error.
sub run {
  my ($self, %opt) = @_;
  my $r = $self->check;
  return $r unless $r->{action} eq 'update';

  if ($opt{dry_run}) {
    $r->{reason} = "would apply: $r->{reason}";
    return $r;
  }

  my ($ok, $msg) = $self->_fast_forward;
  return {%$r, action => 'error', reason => $msg} unless $ok;
  $r->{action} = 'updated';

  if (defined $self->{restart_cmd} && length $self->{restart_cmd}) {
    my $rc = Iczelia::Process::run_capped(
      ['sh', '-c', $self->{restart_cmd}],
      timeout => $self->{timeout},
    );
    if (defined $rc) {
      $r->{restarted} = 1;
    }
    else {
      $r->{restarted}     = 0;
      $r->{restart_error} = "restart command failed: $self->{restart_cmd}";
    }
  }
  return $r;
}

1;
