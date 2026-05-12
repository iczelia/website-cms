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
use File::Path qw(make_path);
use FindBin    ();
use lib "$FindBin::Bin/../lib";

BEGIN {
  my $have_git =
    grep {-x "$_/git"} split /:/, ($ENV{PATH} || '/usr/bin:/bin');
  plan skip_all => 'git not in PATH' unless $have_git;
}

use Iczelia::SelfUpdate;

# Deterministic, isolated git: no user/system config, fixed identity.
local $ENV{GIT_CONFIG_GLOBAL}    = '/dev/null';
local $ENV{GIT_CONFIG_SYSTEM}    = '/dev/null';
local $ENV{GIT_AUTHOR_NAME}      = 'T';
local $ENV{GIT_AUTHOR_EMAIL}     = 't@example.invalid';
local $ENV{GIT_COMMITTER_NAME}   = 'T';
local $ENV{GIT_COMMITTER_EMAIL}  = 't@example.invalid';

my $tmp    = File::Temp->newdir;
my $remote = "$tmp/remote";
my $local  = "$tmp/local";

sub g {
  my @a = @_;
  system('git', @a) == 0 or die "git @a exited $?";
}

sub write_version {
  my ($dir, $v) = @_;
  make_path("$dir/lib");
  open my $fh, '>', "$dir/lib/Iczelia.pm" or die "$dir/lib/Iczelia.pm: $!";
  print $fh "package Iczelia;\nour \$VERSION = '$v';\n1;\n";
  close $fh;
}

sub local_version {
  open my $fh, '<', "$local/lib/Iczelia.pm" or die $!;
  local $/;
  my ($v) = <$fh> =~ /\$VERSION\s*=\s*'([^']+)'/;
  return $v;
}

sub local_head { chomp(my $h = `git -C "$local" rev-parse HEAD`); $h }

make_path($remote);
g('-C', $remote, 'init', '-q');
write_version($remote, '0.1.0');
g('-C', $remote, 'add', '-A');
g('-C', $remote, 'commit', '-q', '-m', 'v0.1.0');
chomp(my $base = `git -C "$remote" rev-parse --abbrev-ref HEAD`);
chomp(my $v010 = `git -C "$remote" rev-parse HEAD`);

g('-C', $remote, 'checkout', '-q', '-b', 'patch');
write_version($remote, '0.1.4');
g('-C', $remote, 'add', '-A');
g('-C', $remote, 'commit', '-q', '-m', 'v0.1.4');

g('-C', $remote, 'checkout', '-q', $base);
g('-C', $remote, 'checkout', '-q', '-b', 'minor');
write_version($remote, '0.2.0');
g('-C', $remote, 'add', '-A');
g('-C', $remote, 'commit', '-q', '-m', 'v0.2.0');

g('-C', $remote, 'checkout', '-q', $base);

# Clone with the base branch checked out: local HEAD is v0.1.0.
g('clone', '-q', '--branch', $base, $remote, $local);

sub fresh {
  g('-C', $local, 'reset', '--hard', '-q', $v010);
  g('-C', $local, 'checkout', '-q', '--', '.');
}

{
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.0');
  my $r = $u->check;
  is($r->{action},         'update', 'patch bump -> update');
  is($r->{remote_version}, '0.1.4',  'sees remote 0.1.4');
  is($r->{remote_ref},     'origin/patch', 'ref reported');
}

{
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.4');
  is($u->check->{action}, 'noop', 'same version -> noop');
}

{
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.2');
  my $r = $u->check;
  is($r->{action}, 'update', 'multi-step patch bump still -> update');
}

{
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'minor',
    current => '0.1.0');
  my $r = $u->check;
  is($r->{action},         'skip',  'minor bump -> skip');
  is($r->{remote_version}, '0.2.0', 'sees remote 0.2.0');
  like($r->{reason}, qr/not a patch-level bump/, 'skip reason');
}

{
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.9');
  my $r = $u->check;
  is($r->{action}, 'skip', 'older remote -> skip (no downgrade)');
  like($r->{reason}, qr/downgrade/, 'downgrade reason');
}

{
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => 'not-a-version');
  is($u->check->{action}, 'error', 'unparseable current version -> error');
}

{
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'nope-no-branch',
    current => '0.1.0');
  is($u->check->{action}, 'error', 'missing branch -> error');
}

{
  my $u = Iczelia::SelfUpdate->new(repo_dir => "$tmp", branch => 'patch',
    current => '0.1.0');
  is($u->check->{action}, 'error', 'not a git checkout -> error');
}

# dirty working tree blocks an otherwise-eligible update
{
  open my $fh, '>>', "$local/lib/Iczelia.pm" or die $!;
  print $fh "# scratch\n";
  close $fh;
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.0');
  my $r = $u->check;
  is($r->{action}, 'skip', 'dirty tree -> skip');
  like($r->{reason}, qr/local changes/, 'dirty reason');
  fresh();
}

# dry run changes nothing
{
  fresh();
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.0');
  my $r = $u->run(dry_run => 1);
  is($r->{action},     'update', 'dry run keeps action=update');
  is(local_version(),  '0.1.0',  'dry run left the file alone');
  like($r->{reason}, qr/would apply/, 'dry-run reason');
}

# real run fast-forwards the checkout
{
  fresh();
  my $u = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.0');
  my $r = $u->run;
  is($r->{action},    'updated', 'run -> updated');
  is(local_version(), '0.1.4',   'checkout moved to 0.1.4');
  chomp(my $patch_head = `git -C "$remote" rev-parse patch`);
  is(local_head(), $patch_head, 'HEAD fast-forwarded to origin/patch');
  ok(!exists $r->{restarted}, 'no restart attempted without a command');

  # already there now
  my $u2 = Iczelia::SelfUpdate->new(repo_dir => $local, branch => 'patch',
    current => '0.1.4');
  is($u2->run->{action}, 'noop', 'second run -> noop');
}

# restart command runs after a successful update
{
  fresh();
  my $marker = "$tmp/restarted";
  my $u = Iczelia::SelfUpdate->new(
    repo_dir    => $local,
    branch      => 'patch',
    current     => '0.1.0',
    restart_cmd => "touch '$marker'",
  );
  my $r = $u->run;
  is($r->{action},    'updated', 'updated with restart command');
  is($r->{restarted}, 1,         'restart reported');
  ok(-e $marker, 'restart command actually ran');
}

# a failing restart command is surfaced (and the update still stands)
{
  fresh();
  my $u = Iczelia::SelfUpdate->new(
    repo_dir    => $local,
    branch      => 'patch',
    current     => '0.1.0',
    restart_cmd => 'exit 3',
  );
  my $r = $u->run;
  is($r->{action},    'updated', 'update stands even if restart fails');
  is($r->{restarted}, 0,         'restart marked failed');
  ok($r->{restart_error}, 'restart_error set');
}

done_testing;
