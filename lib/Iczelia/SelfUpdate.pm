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

# In-place git self-updater driven by signed-style release tags.
#
# Each tag is `<prefix>X.Y.Z` (default prefix `v`). The updater fetches
# tags from the remote, finds the tag whose version is *exactly one
# patch higher* than the running version on the same major.minor, and
# fast-forwards the checkout to that tag. A single invocation never
# bumps by more than 0.0.1; if the maintainer skipped a patch number
# the updater stays put until that patch is released. Minor/major
# bumps are always reported and left for a human.
#
# Branches play no role in target selection.
#
# git is shelled out to so we don't grow a dependency; a custom `git`
# path can be injected for tests. Cron-driven via bin/iczelia-update.

sub new {
  my ($class, %arg) = @_;
  my $self = {
    repo_dir    => $arg{repo_dir} || _repo_root(),
    remote      => defined $arg{remote} ? $arg{remote} : 'origin',
    tag_prefix  => defined $arg{tag_prefix} ? $arg{tag_prefix} : 'v',
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

# Parse `git tag --list '<prefix>*'` output into a list of
# {tag => name, ver => [x,y,z]} hashrefs.
sub _parse_tags {
  my ($self, $raw) = @_;
  my $prefix_re = quotemeta $self->{tag_prefix};
  my @out;
  for my $line (split /\n/, $raw) {
    $line =~ s/^\s+|\s+$//g;
    next unless length $line;
    next unless $line =~ /\A$prefix_re([0-9]+)\.([0-9]+)\.([0-9]+)\z/;
    push @out,
      {tag => $line, ver => [$1 + 0, $2 + 0, $3 + 0]};
  }
  return \@out;
}

# Inspect remote tags vs. current without touching the working tree.
# Returns a hashref:
#   action         => 'update' | 'noop' | 'skip' | 'error'
#   reason         => human-readable line
#   current        => running version
#   remote_version => version selected (when an eligible tag exists)
#   target_tag     => tag name selected (when 'update')
sub check {
  my ($self) = @_;
  my %out = (current => $self->{current});

  my $cur = _parse_version($self->{current});
  return {%out, action => 'error',
    reason => "unparseable current version '$self->{current}'"}
    unless $cur;

  return {%out, action => 'error',
    reason => "$self->{repo_dir} is not a git checkout"}
    unless defined $self->_git('rev-parse', '--git-dir');

  # Pull tag refs from the remote. `--tags --force` so an upstream
  # tag re-pointing (e.g. a corrected release tag) overwrites the
  # local ref instead of silently keeping the old commit.
  if (length $self->{remote}) {
    return {%out, action => 'error',
      reason => "git fetch $self->{remote} --tags failed"}
      unless defined
      $self->_git('fetch', '--quiet', '--tags', '--force', $self->{remote});
  }

  my $raw = $self->_git('tag', '--list', "$self->{tag_prefix}*");
  return {%out, action => 'error', reason => 'git tag --list failed'}
    unless defined $raw;

  my $tags = $self->_parse_tags($raw);
  unless (@$tags) {
    return {%out, action => 'noop',
      reason => "no release tags matching $self->{tag_prefix}X.Y.Z"};
  }

  # The next eligible step is exactly +0.0.1 from current.
  my $step_ver = [$cur->[0], $cur->[1], $cur->[2] + 1];
  my ($target) =
    grep {_cmp_version($_->{ver}, $step_ver) == 0} @$tags;

  unless ($target) {

    # Distinguish "you're past the latest patch on this minor" from
    # "next available tag is a minor/major bump" from "patches were
    # skipped past +1, we won't leap".
    my @newer = grep {_cmp_version($_->{ver}, $cur) > 0} @$tags;
    unless (@newer) {
      return {%out, action => 'noop',
        reason => "already at latest $self->{tag_prefix}"
          . join('.', @$cur)};
    }
    my @same_mm = grep {
           $_->{ver}[0] == $cur->[0]
        && $_->{ver}[1] == $cur->[1]
    } @newer;
    if (@same_mm) {
      my $next_avail = (sort {_cmp_version($a->{ver}, $b->{ver})} @same_mm)[0];
      return {%out, action => 'skip',
        reason => "$self->{tag_prefix}"
          . join('.', @$step_ver)
          . " not released; nearest higher patch is "
          . $next_avail->{tag}
          . " (update by 0.0.1 only)"};
    }
    return {%out, action => 'skip',
      reason => "next release is a minor/major bump; update manually"};
  }

  $out{remote_version} = join '.', @{$target->{ver}};
  $out{target_tag}     = $target->{tag};

  # Eligible step found; refuse if the working tree has tracked
  # modifications. A fast-forward would either fail or clobber them.
  my $dirty = $self->_git('status', '--porcelain', '--untracked-files=no');
  return {%out, action => 'error', reason => 'git status failed'}
    unless defined $dirty;
  return {%out, action => 'skip',
    reason => 'working tree has local changes; update manually'}
    if length $dirty;

  return {%out, action => 'update',
    reason => "patch step $self->{current} -> $out{remote_version}"};
}

# Fast-forward the checkout to the chosen tag. Returns ($ok, $message).
sub _fast_forward {
  my ($self, $target_tag) = @_;
  return (1, undef)
    if defined $self->_git('merge', '--ff-only', $target_tag);
  return (0,
    "fast-forward to $target_tag failed (diverged history?)");
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

  my ($ok, $msg) = $self->_fast_forward($r->{target_tag});
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
