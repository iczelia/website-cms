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

package Iczelia::Git;
use strict;
use warnings;
use Carp        qw(croak);
use Encode      ();
use File::Path  qw(make_path remove_tree);
use File::Spec  ();
use File::Temp  ();
use IPC::Open3  ();
use POSIX       ();
use Symbol      qw(gensym);

# Plain shell-out wrapper around the system `git` CLI. Every function
# returns plain Perl data so handlers and tests never depend on a
# library object. $repo is always the on-disk absolute path of the
# bare repository.
#
# We deliberately avoid Git::Raw / libgit2: a vendored-libgit2 cpanm
# install was crashing at runtime on aarch64, and the system `git`
# binary is the universally-shipped, well-tested implementation.
# IPC::Open3 with the list-form arglist means no shell interpolation,
# so callers don't need to escape anything.

# Hard-coded env we set on every git invocation:
#   * GIT_TERMINAL_PROMPT=0: never block on a tty prompt for credentials.
#   * GIT_ASKPASS=/bin/true: same, in case git decides to ask via askpass.
#   * GIT_CONFIG_GLOBAL=/dev/null: ignore any ~/.gitconfig the daemon
#     user happens to have.
#   * GIT_CONFIG_SYSTEM=/dev/null: same for /etc/gitconfig.
#   * HOME=/tmp: fallback for anything else that resolves home.
my %GIT_ENV = (
  GIT_TERMINAL_PROMPT => 0,
  GIT_ASKPASS         => '/bin/true',
  GIT_CONFIG_GLOBAL   => '/dev/null',
  GIT_CONFIG_SYSTEM   => '/dev/null',
  HOME                => '/tmp',
);

# Default execution caps. Calls that walk large repos (log walks, big
# diffs) override per-call.
use constant {
  DEFAULT_TIMEOUT_S => 60,
  DEFAULT_MAX_BYTES => 64 * 1024 * 1024,   # output cap per git call
  BLOB_MAX_BYTES    => 16 * 1024 * 1024,   # blob raw / cat-file body
  COMMIT_DIFF_CAP   => 1024 * 1024,        # truncate huge diffs
  US                => "\x1f",             # field separator in formats
  RS                => "\x1e",             # record separator
};

# Probe the git binary once. Memoised across calls in the process.
# ICZELIA_NO_GIT=1 is the operator kill-switch (kept from the earlier
# Git::Raw-era hotfix so existing systemd units still work).
my $AVAILABLE;
sub available {
  return $AVAILABLE if defined $AVAILABLE;
  return $AVAILABLE = 0 if $ENV{ICZELIA_NO_GIT};
  my $bin = _find_git();
  return $AVAILABLE = ($bin ? 1 : 0);
}

sub _find_git {
  for my $dir (split /:/, ($ENV{PATH} || '/usr/bin:/usr/local/bin')) {
    my $p = "$dir/git";
    return $p if -x $p;
  }
  return undef;
}

sub _need {
  return if available();
  croak "git binary not on PATH";
}

# Compose and validate the on-disk path for a repo's bare directory.
# Rejects any slug that could escape var/git/.
sub bare_repo_path {
  my ($var_dir, $slug) = @_;
  croak "var_dir required" unless defined $var_dir && length $var_dir;
  croak "invalid slug"
    unless defined $slug
    && $slug =~ /^[a-z0-9][a-z0-9-]*\z/
    && length($slug) <= 63;
  return File::Spec->catdir($var_dir, 'git', "$slug.git");
}

# Public mirror URLs only in v1. http(s) schemes only. The character
# class keeps SSRF surface small.
sub valid_mirror_url {
  my ($u) = @_;
  return 0 unless defined $u && length $u;
  return 0 if $u =~ /[\s\x00-\x1f\x7f]/;
  return 0 unless $u =~ m{\A https? :// [A-Za-z0-9._\-]+ (?::\d+)? (?:/\S*)? \z}x;
  return 1;
}

# Run git with a list of args. Returns (stdout_bytes, stderr_bytes, exit_code).
# stdin is closed immediately; stdout/stderr are read fully (memory-bounded
# by $max_bytes). NEVER passes args through a shell.
sub _run {
  my (%opt) = @_;
  _need;
  my @args     = @{$opt{args} || croak "args required"};
  my $cwd      = $opt{cwd};
  my $timeout  = $opt{timeout}  // DEFAULT_TIMEOUT_S;
  my $max_size = $opt{max_size} // DEFAULT_MAX_BYTES;
  my $stdin    = $opt{stdin};

  my $bin = _find_git() or croak "git binary not on PATH";

  # `git -C $cwd ...` scopes a single invocation -- supported and
  # safer than chdir() in a child.
  unshift @args, '-C', $cwd if defined $cwd && length $cwd;

  my ($wr, $rd, $er);
  $er = gensym;

  local %ENV = (%ENV, %GIT_ENV);

  my $pid = IPC::Open3::open3($wr, $rd, $er, $bin, @args);
  binmode $wr if defined $stdin;
  binmode $rd;
  binmode $er;
  if (defined $stdin && length $stdin) {
    print $wr $stdin;
  }
  close $wr;

  my ($out, $err) = ('', '');
  my $deadline = time + $timeout;
  my $bufsize  = 65536;
  my $rin = '';
  vec($rin, fileno($rd), 1) = 1;
  vec($rin, fileno($er), 1) = 1;

  while (1) {
    my $remaining = $deadline - time;
    last if $remaining <= 0;
    my $rout;
    my $n = select($rout = $rin, undef, undef, $remaining);
    last if $n <= 0;
    if (vec($rout, fileno($rd), 1)) {
      my $chunk;
      my $r = sysread($rd, $chunk, $bufsize);
      if (!defined $r) { last }
      elsif ($r == 0)  { vec($rin, fileno($rd), 1) = 0 }
      else {
        $out .= $chunk;
        if (length($out) > $max_size) {
          kill 'TERM', $pid;
          $err .= "[truncated: output exceeded $max_size bytes]\n";
          last;
        }
      }
    }
    if (vec($rout, fileno($er), 1)) {
      my $chunk;
      my $r = sysread($er, $chunk, $bufsize);
      if (!defined $r) { last }
      elsif ($r == 0)  { vec($rin, fileno($er), 1) = 0 }
      else {
        $err .= $chunk;
        if (length($err) > 256 * 1024) {
          $err = substr($err, 0, 256 * 1024) . "\n[truncated]\n";
          vec($rin, fileno($er), 1) = 0;
        }
      }
    }
    last unless vec($rin, fileno($rd), 1) || vec($rin, fileno($er), 1);
  }

  if (time >= $deadline && kill(0, $pid)) {
    kill 'TERM', $pid;
    POSIX::sleep(1);
    kill 'KILL', $pid if kill(0, $pid);
    $err .= "[killed: $timeout s timeout]\n";
  }
  close $rd;
  close $er;
  waitpid $pid, 0;
  my $rc = $?;
  return ($out, $err, $rc);
}

# Initialise a bare repo at $path with HEAD on refs/heads/main.
sub init_bare {
  my ($path) = @_;
  _need;
  make_path($path);
  my (undef, $err, $rc) = _run(
    args => [qw(init --bare --initial-branch=main --), $path],
  );
  croak "git init --bare: $err" if $rc != 0;
  return $path;
}

sub open_bare {
  my ($path) = @_;
  _need;
  return undef unless -d "$path/objects" || -f "$path/HEAD";
  return $path;
}

sub head_sha {
  my ($path) = @_;
  _need;
  return undef unless -d $path;
  my ($out, undef, $rc) = _run(
    cwd  => $path,
    args => [qw(rev-parse HEAD)],
  );
  return undef if $rc != 0;
  $out =~ s/\s+\z//;
  return $out =~ /^[0-9a-f]{4,64}$/ ? $out : undef;
}

sub _parse_log_row {
  my ($line) = @_;
  my ($sha, $short, $author, $email, $ts, $subject)
    = split /\Q@{[US]}\E/, $line, 6;
  return undef unless defined $sha && $sha =~ /^[0-9a-f]{4,64}$/;
  return {
    sha     => $sha,
    short   => ($short // substr($sha, 0, 10)),
    author  => ($author // ''),
    email   => ($email  // ''),
    ts      => ($ts // 0) + 0,
    subject => (defined $subject ? $subject : ''),
    body    => '',
  };
}

# Walk commits. Options: ref (default HEAD), limit, skip, path. Always
# returns an arrayref (possibly empty); never throws.
sub log {
  my ($path, %opt) = @_;
  _need;
  return [] unless -d $path;
  my $ref   = defined $opt{ref}   && length $opt{ref}   ? $opt{ref}   : 'HEAD';
  my $limit = $opt{limit} // 50;
  my $skip  = $opt{skip}  // 0;
  return [] unless $ref =~ m{^[A-Za-z0-9._/\-]+\z};
  return [] unless $limit =~ /^\d+$/ && $skip =~ /^\d+$/;

  my $fmt = join(US, qw(%H %h %an %ae %at %s));
  my @args = (
    'log', "--pretty=format:$fmt", "--max-count=$limit",
    "--skip=$skip", $ref,
  );
  if (defined $opt{path} && length $opt{path}) {
    return [] unless _safe_path($opt{path});
    push @args, '--', $opt{path};
  }
  my ($out, undef, $rc) = _run(cwd => $path, args => \@args);
  return [] if $rc != 0;

  my @rows;
  for my $line (split /\n/, $out) {
    next unless length $line;
    my $r = _parse_log_row($line);
    push @rows, $r if $r;
  }
  return \@rows;
}

sub _refs {
  my ($path, $prefix, $date_field) = @_;
  _need;
  return [] unless -d $path;
  $date_field ||= 'committerdate';
  my $fmt = join(US,
    '%(refname:short)', '%(objectname)', "%($date_field:unix)");
  my ($out, undef, $rc) = _run(
    cwd  => $path,
    args => ['for-each-ref', "--sort=-$date_field", "--format=$fmt", $prefix],
  );
  return [] if $rc != 0;
  my @out;
  for my $line (split /\n/, $out) {
    next unless length $line;
    my ($name, $sha, $ts) = split /\Q@{[US]}\E/, $line, 3;
    next unless defined $name && length $name;
    push @out, { name => $name, sha => ($sha // ''), ts => ($ts // 0) + 0 };
  }
  return \@out;
}

sub branches { _refs($_[0], 'refs/heads/', 'committerdate') }
sub tags     { _refs($_[0], 'refs/tags/',  'creatordate')   }

sub _safe_path {
  my ($p) = @_;
  return 0 unless defined $p;
  return 0 if $p =~ /\0/;
  return 0 if $p =~ m{(?:^|/)\.\.(?:/|$)};
  return 0 if $p =~ m{^/};
  return 0 if length($p) > 4096;
  return 1;
}

# Returns rows shaped like Iczelia::Subpages::directory_entries:
# [{type => 'dir'|'file'|'link'|'submodule', name, size, sha, mode}, ...]
# sorted dirs-first then alphabetical.
sub tree {
  my ($path, $ref, $dir) = @_;
  _need;
  return [] unless -d $path;
  $ref = 'HEAD' unless defined $ref && length $ref;
  return [] unless $ref =~ m{^[A-Za-z0-9._/\-]+\z};
  $dir = '' unless defined $dir;
  $dir =~ s{^/+}{}; $dir =~ s{/+$}{};
  return [] if length $dir && !_safe_path($dir);

  my $spec = length $dir ? "$ref:$dir/" : "$ref:";
  my ($out, undef, $rc) = _run(
    cwd  => $path,
    args => ['ls-tree', '-l', '-z', '--full-name', $spec],
  );
  return [] if $rc != 0;

  # `-z` -> records NUL-terminated. Each: "<mode> <type> <oid> <size>\t<name>"
  my @rows;
  for my $rec (split /\0/, $out) {
    next unless length $rec;
    my ($head, $name) = split /\t/, $rec, 2;
    next unless defined $head && defined $name;
    my ($mode, $type, $oid, $size) = split / +/, $head, 4;
    if (length $dir) {
      my $px = "$dir/";
      $name = substr($name, length $px) if 0 == index($name, $px);
    }
    next if $name eq '' || $name =~ m{/};
    my ($ttype, $sz);
    if ($type eq 'tree')      { $ttype = 'dir';       $sz = undef }
    elsif ($type eq 'blob')   {
      $ttype = ($mode eq '120000') ? 'link' : 'file';
      $sz    = ($size =~ /^\d+$/ ? $size + 0 : undef);
    }
    elsif ($type eq 'commit') { $ttype = 'submodule'; $sz = undef }
    else                      { $ttype = $type;       $sz = undef }
    push @rows, {
      type => $ttype,
      name => $name,
      size => $sz,
      sha  => ($oid // ''),
      mode => ($mode // ''),
    };
  }
  my @dirs  = grep { $_->{type} eq 'dir' } @rows;
  my @other = grep { $_->{type} ne 'dir' } @rows;
  return [
    (sort { $a->{name} cmp $b->{name} } @dirs),
    (sort { $a->{name} cmp $b->{name} } @other),
  ];
}

# Returns ($bytes, $size, $sha). $bytes is undef if oversize.
sub blob {
  my ($path, $ref, $rel, %opt) = @_;
  _need;
  return (undef, undef, undef) unless -d $path;
  $ref = 'HEAD' unless defined $ref && length $ref;
  return (undef, undef, undef) unless $ref =~ m{^[A-Za-z0-9._/\-]+\z};
  return (undef, undef, undef) unless _safe_path($rel);

  my $spec = "$ref:$rel";
  my $max  = $opt{max_bytes} // BLOB_MAX_BYTES;

  my ($sout, undef, $src) = _run(
    cwd  => $path,
    args => ['cat-file', '-s', $spec],
  );
  return (undef, undef, undef) if $src != 0;
  $sout =~ s/\s+\z//;
  return (undef, undef, undef) unless $sout =~ /^\d+$/;
  my $size = $sout + 0;

  my ($oout) = _run(cwd => $path, args => ['rev-parse', $spec]);
  $oout =~ s/\s+\z//;
  my $sha = $oout =~ /^[0-9a-f]{4,64}$/ ? $oout : '';

  return (undef, $size, $sha) if $size > $max;

  my ($body, undef, $brc) = _run(
    cwd      => $path,
    args     => ['cat-file', 'blob', $spec],
    max_size => $max + 4096,
  );
  return (undef, $size, $sha) if $brc != 0;
  return ($body, $size, $sha);
}

sub commit {
  my ($path, $sha) = @_;
  _need;
  return undef unless -d $path;
  return undef unless defined $sha && $sha =~ /^[0-9a-f]{4,64}\z/i;
  $sha = lc $sha;

  my $fmt = join(US, qw(%H %h %an %ae %at %P %s %b));
  my ($mout, undef, $mrc) = _run(
    cwd  => $path,
    args => ['log', '-1', "--pretty=format:$fmt", $sha],
  );
  return undef if $mrc != 0 || !length $mout;

  my ($H, $short, $an, $ae, $at, $P, $subj, @body)
    = split /\Q@{[US]}\E/, $mout, 8;
  my $body = defined $body[0] ? $body[0] : '';
  $body =~ s/\s+\z//;
  my @parents = split /\s+/, ($P // '');

  my @diff_args = ('show', '--no-color', '--unified=3',
    '--pretty=format:', '--no-notes', $sha);
  my ($diff_out, undef, $drc) = _run(
    cwd      => $path,
    args     => \@diff_args,
    max_size => COMMIT_DIFF_CAP + 4096,
  );
  my $diff = $drc == 0 ? ($diff_out // '') : '';
  $diff =~ s/^\s+//;
  if (length($diff) > COMMIT_DIFF_CAP) {
    $diff = substr($diff, 0, COMMIT_DIFF_CAP)
      . "\n\n[diff truncated: exceeded "
      . COMMIT_DIFF_CAP . " bytes]\n";
  }

  return {
    sha     => $H,
    short   => $short,
    author  => ($an // ''),
    email   => ($ae // ''),
    ts      => ($at // 0) + 0,
    subject => ($subj // ''),
    body    => $body,
    parents => \@parents,
    diff    => $diff,
  };
}

sub last_commit_for_path {
  my ($path, $ref, $rel) = @_;
  my $rows = Iczelia::Git::log($path, ref => $ref, path => $rel, limit => 1);
  return $rows && @$rows ? $rows->[0] : undef;
}

# Build an initial commit (or overlay) from a flat list of files. The
# bare repo at $repo_path is the push target; we stage in a fresh
# temp working tree, commit, push to $branch, then nuke the temp.
# files: [{path => str, content => bytes, is_executable => 0|1}]
sub import_zip {
  my ($repo_path, $files, %opt) = @_;
  _need;
  croak "no files to import" unless $files && @$files;
  my $branch = $opt{branch}       // 'main';
  my $name   = $opt{author_name}  // 'iczelia';
  my $email  = $opt{author_email} // 'noreply@iczelia.net';
  my $msg    = $opt{message}      // 'import';
  return (0, "bad branch name") unless $branch =~ m{^[A-Za-z0-9._/\-]+\z};

  my $work = File::Temp->newdir(CLEANUP => 1);
  my $wt   = "$work";

  for my $f (@$files) {
    my $rel = $f->{path};
    return (0, "unsafe path $rel") unless _safe_path($rel);
    my $abs = "$wt/$rel";
    my ($dir) = $abs =~ m{^(.+)/[^/]+$};
    make_path($dir) if defined $dir && !-d $dir;
    open my $fh, '>:raw', $abs or return (0, "write $rel: $!");
    print $fh ($f->{content} // '');
    close $fh;
    chmod 0755, $abs if $f->{is_executable};
  }

  local %ENV = (
    %ENV, %GIT_ENV,
    GIT_AUTHOR_NAME     => $name,
    GIT_AUTHOR_EMAIL    => $email,
    GIT_COMMITTER_NAME  => $name,
    GIT_COMMITTER_EMAIL => $email,
  );

  for my $argset (
    [ 'init', '--quiet', "--initial-branch=$branch" ],
    [ 'add', '-A' ],
    [ 'commit', '--quiet', '-m', $msg ],
    [ 'push', '--quiet', $repo_path, "HEAD:refs/heads/$branch" ],
  ) {
    my ($_o, $err, $rc) = _run(cwd => $wt, args => $argset, timeout => 300);
    if ($rc != 0) {
      chomp $err;
      return (0, "git " . $argset->[0] . ": $err");
    }
  }
  return (1, undef);
}

# Mirror clone: `git clone --mirror`. Refuses non-http(s) URLs.
sub clone_mirror {
  my ($repo_path, $url) = @_;
  _need;
  return (0, "invalid mirror url", undef)
    unless valid_mirror_url($url);
  make_path($repo_path);
  remove_tree($repo_path) if -e $repo_path && !-d "$repo_path/objects";
  my (undef, $err, $rc) = _run(
    args    => [qw(clone --mirror --quiet --), $url, $repo_path],
    timeout => 600,
  );
  if ($rc != 0) {
    chomp $err;
    return (0, "clone: $err", undef);
  }
  return (1, undef, head_sha($repo_path));
}

# Pull/update a mirror. Calls `git remote update --prune`.
sub pull_mirror {
  my ($repo_path) = @_;
  _need;
  return (0, "no such repo", undef) unless -d "$repo_path/objects";
  my (undef, $err, $rc) = _run(
    cwd     => $repo_path,
    args    => [qw(remote update --prune)],
    timeout => 600,
  );
  if ($rc != 0) {
    chomp $err;
    return (0, "remote update: $err", head_sha($repo_path));
  }
  return (1, undef, head_sha($repo_path));
}

# Bulk per-directory "last commit per row" walker. For (head, dir),
# walks up to $limit commits with --name-only and buckets each
# changed path to its immediate child under $dir. The first commit
# (newest) touching a child wins. Returns { name => { sha, ts, subject } }.
sub last_commits_for_dir {
  my ($repo_path, $ref, $dir, %opt) = @_;
  _need;
  return {} unless -d $repo_path;
  $ref = 'HEAD' unless defined $ref && length $ref;
  return {} unless $ref =~ m{^[A-Za-z0-9._/\-]+\z};
  $dir = '' unless defined $dir;
  $dir =~ s{^/+}{}; $dir =~ s{/+$}{};
  return {} if length $dir && !_safe_path($dir);
  my $limit = $opt{limit} // 1500;

  my $fmt = "${\RS}" . join(US, qw(%H %ct %s));
  my @args = (
    'log', "--pretty=format:$fmt", '--name-only', '--no-renames',
    "--max-count=$limit", $ref,
  );
  push @args, '--', $dir if length $dir;
  my ($out, undef, $rc) = _run(
    cwd      => $repo_path,
    args     => \@args,
    max_size => 32 * 1024 * 1024,
  );
  return {} if $rc != 0;

  my $prefix = length $dir ? "$dir/" : '';
  my %seen;
  for my $rec (split /\Q@{[RS]}\E/, $out) {
    next unless length $rec;
    my ($head, @paths) = split /\n/, $rec;
    my ($sha, $ts, $subj) = split /\Q@{[US]}\E/, $head, 3;
    next unless defined $sha && $sha =~ /^[0-9a-f]{4,64}$/;
    for my $p (@paths) {
      next unless length $p;
      next unless !length($prefix) || 0 == index($p, $prefix);
      my $rest = length($prefix) ? substr($p, length $prefix) : $p;
      my ($child) = split m{/}, $rest, 2;
      next unless defined $child && length $child;
      next if exists $seen{$child};
      $seen{$child} = {
        sha     => $sha,
        ts      => ($ts // 0) + 0,
        subject => ($subj // ''),
      };
    }
  }
  return \%seen;
}

1;
