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

package Iczelia::Process;
use strict;
use warnings;
use Carp       qw(croak);
use IO::Select ();
use IPC::Open3 ();
use POSIX      ();
use Symbol     qw(gensym);

# Wall-clock-bounded command runner. Drains stdout+stderr concurrently
# so a chatty child can't wedge on a full stderr pipe.
# Options: body, timeout (s, default 8), max_output (default 16 MiB).

sub run_capped {
  my ($cmd, %opt) = @_;
  croak "cmd arrayref required"
    unless ref $cmd eq 'ARRAY' && @$cmd;
  my $body       = $opt{body};
  my $timeout    = $opt{timeout}    // 8;
  my $max_output = $opt{max_output} // 16 * 1024 * 1024;

  my $out = '';
  my $rc;
  my $pid;
  my $oversize = 0;
  eval {
    local $SIG{PIPE} = 'IGNORE';
    local $SIG{ALRM} = sub {die "alarm\n"};
    my ($wtr, $rdr, $eh);
    $eh  = gensym;
    $pid = IPC::Open3::open3($wtr, $rdr, $eh, @$cmd);
    binmode $wtr;
    binmode $rdr;
    binmode $eh;
    alarm($timeout);
    print $wtr $body if defined $body;
    close $wtr;

    my $sel = IO::Select->new($rdr, $eh);
    while ($sel->count) {

      # Block until something is ready; the alarm bounds wallclock.
      for my $fh ($sel->can_read) {
        my $buf;
        my $n = sysread($fh, $buf, 65536);
        if (!defined $n) {
          next if $!{EINTR};
          $sel->remove($fh);
          close $fh;
          next;
        }
        if ($n == 0) {
          $sel->remove($fh);
          close $fh;
          next;
        }
        if ($fh == $rdr) {
          $out .= $buf;
          if (length($out) > $max_output) {
            $oversize = 1;
            die "oversize\n";
          }
        }

        # stderr drained, discarded.
      }
    }

    waitpid $pid, 0;
    $rc = $? >> 8;
    alarm(0);
    1;
  } or do {
    my $e = $@;
    eval {alarm(0)};

    # SIGTERM, 0.5s grace, SIGKILL; reap to avoid a zombie.
    if ($pid) {
      kill 'TERM', $pid;
      for (1 .. 5) {
        last if waitpid($pid, POSIX::WNOHANG()) > 0;
        select undef, undef, undef, 0.1;
      }
      kill 'KILL', $pid;
      waitpid $pid, 0;
    }
    warn "Process: $cmd->[0] failed: $e"
      if $e !~ /^(?:alarm|oversize)/;
    return undef;
  };
  return undef if $oversize;
  return undef if !defined $rc || $rc != 0;
  return $out;
}

sub have_bin {
  my $name = shift;
  for my $dir (split /:/, ($ENV{PATH} || '/usr/local/bin:/usr/bin:/bin')) {
    return 1 if -x "$dir/$name";
  }
  return 0;
}

1;
