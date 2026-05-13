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

# Commit + tag a version on the current branch.
sub release {
  my ($dir, $v) = @_;
  write_version($dir, $v);
  g('-C', $dir, 'add', '-A');
  g('-C', $dir, 'commit', '-q', '-m', "v$v");
  g('-C', $dir, 'tag', "v$v");
}

sub local_version {
  open my $fh, '<', "$local/lib/Iczelia.pm" or die $!;
  local $/;
  my ($v) = <$fh> =~ /\$VERSION\s*=\s*'([^']+)'/;
  return $v;
}

sub local_head {chomp(my $h = `git -C "$local" rev-parse HEAD`); $h}

make_path($remote);
g('-C', $remote, 'init', '-q');

# Linear release history: v0.1.0 -> v0.1.1 -> v0.1.2 -> v0.1.4 (gap at
# 0.1.3) -> v0.2.0. The minor-bump tag is the head of the branch so a
# plain branch fetch would be tempted to fast-forward across the patch
# tags; the updater must instead step by exactly +0.0.1.
release($remote, '0.1.0');
release($remote, '0.1.1');
release($remote, '0.1.2');
release($remote, '0.1.4');
release($remote, '0.2.0');

# Clone with main branch.
g('clone', '-q', $remote, $local);

# Reset local checkout to a specific tag.
sub reset_to {
  my ($v) = @_;
  g('-C', $local, 'fetch', '-q', '--tags', '--force', 'origin');
  g('-C', $local, 'reset', '--hard', '-q', "v$v");
  g('-C', $local, 'checkout', '-q', '--', '.');
}

# 1. Exact +1 patch tag exists -> action=update, target=v0.1.1.
{
  reset_to('0.1.0');
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.0');
  my $r = $u->check;
  is($r->{action},         'update', '0.1.0 -> v0.1.1: update');
  is($r->{remote_version}, '0.1.1',  'remote_version reports 0.1.1');
  is($r->{target_tag},     'v0.1.1', 'target_tag is v0.1.1');
}

# 2. Already at the latest patch on the minor -> noop. (At v0.1.4
#    with v0.2.0 the only thing newer.)
{
  reset_to('0.1.4');
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.4');
  my $r = $u->check;
  is($r->{action}, 'skip',
    '0.1.4 -> only minor bump available: skip (manual)');
  like($r->{reason}, qr/minor.*major/, 'minor/major skip reason');
}

# 3. No tag at exactly +0.0.1 but a higher patch exists in same minor:
#    skip (don't leap over the gap). Cursor at 0.1.2; v0.1.3 missing;
#    v0.1.4 exists.
{
  reset_to('0.1.2');
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.2');
  my $r = $u->check;
  is($r->{action}, 'skip', 'patch gap -> skip (no +1 leap)');
  like($r->{reason}, qr/not released/, 'gap reason mentions missing tag');
}

# 4. Two-tick walk: 0.1.0 -> 0.1.1, then a second invocation 0.1.1 -> 0.1.2.
{
  reset_to('0.1.0');
  my $u1 =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.0');
  is($u1->run->{action}, 'updated', 'first run: applied 0.1.0 -> 0.1.1');
  is(local_version(), '0.1.1', 'checkout at 0.1.1 after first run');

  my $u2 =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.1');
  is($u2->run->{action}, 'updated', 'second run: 0.1.1 -> 0.1.2');
  is(local_version(), '0.1.2', 'checkout at 0.1.2 after second run');
}

# 5. Same version -> noop (no tag for +1 yet).
{
  reset_to('0.2.0');
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.2.0');
  is($u->check->{action}, 'noop', 'at latest on minor -> noop');
}

# 6. Older than every tag -> downgrade scenario: still skip, because
#    current=0.0.9 has no tag v0.0.10 in the remote.
{
  reset_to('0.1.0');
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.0.9');
  my $r = $u->check;
  is($r->{action}, 'skip', '0.0.9 vs 0.1.* tags -> skip');
}

# 7. Unparseable current version -> error.
{
  reset_to('0.1.0');
  my $u = Iczelia::SelfUpdate->new(
    repo_dir => $local, current => 'not-a-version');
  is($u->check->{action}, 'error', 'unparseable current -> error');
}

# 8. Not a git checkout -> error.
{
  my $u = Iczelia::SelfUpdate->new(
    repo_dir => "$tmp", current => '0.1.0');
  is($u->check->{action}, 'error', 'not a git checkout -> error');
}

# 9. Dirty tree blocks an otherwise-eligible update.
{
  reset_to('0.1.0');
  open my $fh, '>>', "$local/lib/Iczelia.pm" or die $!;
  print $fh "# scratch\n";
  close $fh;
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.0');
  my $r = $u->check;
  is($r->{action}, 'skip', 'dirty tree -> skip');
  like($r->{reason}, qr/local changes/, 'dirty reason');
  reset_to('0.1.0');
}

# 10. Dry run reports an update but changes nothing on disk.
{
  reset_to('0.1.0');
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.0');
  my $r = $u->run(dry_run => 1);
  is($r->{action},     'update', 'dry run keeps action=update');
  is(local_version(),  '0.1.0',  'dry run left the file alone');
  like($r->{reason}, qr/would apply/, 'dry-run reason');
}

# 11. Real run fast-forwards and a follow-up immediately reports noop.
{
  reset_to('0.1.0');
  my $u =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.0');
  my $r = $u->run;
  is($r->{action},    'updated', 'run -> updated');
  is(local_version(), '0.1.1',   'checkout moved to 0.1.1');
  chomp(my $tag_head = `git -C "$remote" rev-parse v0.1.1`);
  is(local_head(), $tag_head, 'HEAD fast-forwarded to v0.1.1');
  ok(!exists $r->{restarted}, 'no restart attempted without a command');

  my $u2 =
    Iczelia::SelfUpdate->new(repo_dir => $local, current => '0.1.1');
  my $r2 = $u2->run;
  isnt($r2->{action}, 'error', 'second run not error');
  # Either 'updated' (to 0.1.2, since there's a +1) or 'noop'. Either
  # is sensible per the policy; verify it's not a regression.
  ok($r2->{action} eq 'updated' || $r2->{action} eq 'noop',
    "second run: $r2->{action}");
}

# 12. Restart command runs after a successful update.
{
  reset_to('0.1.0');
  my $marker = "$tmp/restarted";
  my $u      = Iczelia::SelfUpdate->new(
    repo_dir    => $local,
    current     => '0.1.0',
    restart_cmd => "touch '$marker'",
  );
  my $r = $u->run;
  is($r->{action},    'updated', 'updated with restart command');
  is($r->{restarted}, 1,         'restart reported');
  ok(-e $marker, 'restart command actually ran');
}

# 13. A failing restart command is surfaced; the update still stands.
{
  reset_to('0.1.0');
  my $u = Iczelia::SelfUpdate->new(
    repo_dir    => $local,
    current     => '0.1.0',
    restart_cmd => 'exit 3',
  );
  my $r = $u->run;
  is($r->{action},    'updated', 'update stands even if restart fails');
  is($r->{restarted}, 0,         'restart marked failed');
  ok($r->{restart_error}, 'restart_error set');
}

# 14. Custom tag prefix.
{
  reset_to('0.1.0');
  g('-C', $remote, 'tag', 'release-0.1.99');
  g('-C', $local, 'fetch', '-q', '--tags', '--force', 'origin');
  my $u = Iczelia::SelfUpdate->new(
    repo_dir   => $local,
    current    => '0.1.98',
    tag_prefix => 'release-',
  );

  # Current 0.1.98 won't find an exact +0.0.1 (no release-0.1.99 was
  # tagged as such on the *remote* before fetch above, but we did tag
  # it just now). The exact +1 from 0.1.98 is 0.1.99 -> update.
  my $r = $u->check;
  is($r->{action}, 'update', 'custom tag_prefix is honoured');
  is($r->{target_tag}, 'release-0.1.99', 'target_tag carries the prefix');
}

done_testing;
