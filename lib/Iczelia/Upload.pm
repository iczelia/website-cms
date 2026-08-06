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

package Iczelia::Upload;
use strict;
use warnings;
use Carp        qw(croak);
use Fcntl       qw(:flock O_WRONLY O_CREAT O_RDONLY);
use File::Path  qw(make_path);
use File::Spec  ();

# Resumable chunked upload sessions.
#
# An admin-side JS uploader splits a big file into ~2 MB chunks and
# POSTs each one to /admin/upload/chunk; this module owns the
# on-disk file + DB row that anchor that session. A subsequent
# handler (backup import, subpages create/rezip, ...) calls claim()
# to take ownership of the assembled path, run its processing, and
# call cleanup() when done.
#
# Two constraints keep this safe:
#   * each session is bound to one admin sid; another logged-in admin
#     cannot resume someone else's upload;
#   * a hard total-size cap (HARD_MAX) keeps an attacker who guessed
#     a CSRF token from filling the volume.

use constant {
  ID_BYTES     => 24,                      # 48 hex chars
  MAX_CHUNK    => 8 * 1024 * 1024,         # per /admin/upload/chunk POST
  HARD_MAX     => 1024 * 1024 * 1024 * 4,  # 4 GiB per session
  STALE_AFTER  => 24 * 3600,               # cleanup unfinalized after a day
};

sub new {
  my ($class, %arg) = @_;
  croak "db required"      unless $arg{db};
  croak "tmp_dir required" unless $arg{tmp_dir};
  make_path($arg{tmp_dir}) unless -d $arg{tmp_dir};
  return bless {
    db       => $arg{db},
    tmp_dir  => $arg{tmp_dir},
    max_size => $arg{max_size} || HARD_MAX,
  }, $class;
}

# Cryptographic id; uses /dev/urandom so two parallel inits never
# collide. Returns hex string. Caller persists it via init() below.
sub _mint_id {
  open my $fh, '<:raw', '/dev/urandom' or croak "/dev/urandom: $!";
  my $bytes;
  sysread($fh, $bytes, ID_BYTES);
  close $fh;
  return unpack 'H*', $bytes;
}

sub _path_for {
  my ($self, $id) = @_;
  return File::Spec->catfile($self->{tmp_dir}, "upload-$id.dat");
}

sub _row {
  my ($self, $id) = @_;
  return $self->{db}->row(
    'SELECT * FROM upload_sessions WHERE id=?', $id);
}

# Best-effort GC: drop unfinalized sessions older than a day. Called
# from init() so the table never grows past the live working set.
sub _gc_stale {
  my ($self) = @_;
  my $cutoff = time - STALE_AFTER;
  my $stale = $self->{db}->all(
    q{SELECT id FROM upload_sessions
       WHERE finalized_at IS NULL AND created_at < ?}, $cutoff
  );
  for my $r (@$stale) {
    eval {
      unlink $self->_path_for($r->{id});
      $self->{db}->do_(
        'DELETE FROM upload_sessions WHERE id=?', $r->{id});
    };
  }
}

# Start a new session bound to $sid. $filename is optional metadata
# (used by handlers for content-type hints / nicer error messages).
sub init {
  my ($self, $sid, %opt) = @_;
  croak "sid required" unless defined $sid && length $sid;
  $self->_gc_stale;
  my $id = _mint_id();
  my $path = $self->_path_for($id);
  # Create the empty file so first chunk's append doesn't race.
  open my $fh, '>', $path or croak "open $path: $!";
  close $fh;
  $self->{db}->do_(
    q{INSERT INTO upload_sessions(id, sid, filename, size, created_at)
        VALUES(?,?,?,0,strftime('%s','now'))},
    $id, $sid, $opt{filename}
  );
  return $id;
}

# Append $bytes at $offset for upload $id (must belong to $sid).
# Returns (new_size, error). On any mismatch (wrong sid, offset gap,
# size cap exceeded) the bytes are NOT written and an error string is
# returned. Concurrent chunks on the same session are serialised by
# flock so out-of-order POSTs (from a JS retry) can't interleave.
sub append {
  my ($self, $id, $sid, $offset, $bytes) = @_;
  $bytes = '' unless defined $bytes;
  my $row = $self->_row($id);
  return (undef, 'unknown upload') unless $row;
  return (undef, 'not your upload') unless $row->{sid} eq $sid;
  return (undef, 'already finalized') if $row->{finalized_at};
  return (undef, 'chunk too large')
    if length($bytes) > MAX_CHUNK;

  my $path = $self->_path_for($id);
  my $fh;
  if (!open $fh, '+<', $path) {
    return (undef, "open: $!") unless open $fh, '+>', $path;
  }
  binmode $fh;
  flock($fh, LOCK_EX) or do { close $fh; return (undef, "lock: $!") };

  # The file is authoritative while locked.  In particular, a proxy can
  # lose the response after a successful write and make the client replay
  # the same chunk.  Accept an identical overlap so retries are idempotent;
  # reject an overlap containing different bytes.
  my $current = -s $fh;
  if ($offset > $current) {
    flock($fh, LOCK_UN); close $fh;
    return (undef, 'offset mismatch');
  }
  my $overlap = $current - $offset;
  $overlap = length($bytes) if $overlap > length($bytes);
  if ($overlap > 0) {
    seek($fh, $offset, 0) or do {
      my $e = $!; flock($fh, LOCK_UN); close $fh;
      return (undef, "seek: $e");
    };
    my $existing = '';
    while (length($existing) < $overlap) {
      my $n = sysread($fh, $existing, $overlap - length($existing),
        length($existing));
      if (!defined $n || $n == 0) {
        my $e = $! || 'short read';
        flock($fh, LOCK_UN); close $fh;
        return (undef, "read: $e");
      }
    }
    if ($existing ne substr($bytes, 0, $overlap)) {
      flock($fh, LOCK_UN); close $fh;
      return (undef, 'offset mismatch');
    }
  }

  my $remaining = substr($bytes, $overlap);
  if ($current + length($remaining) > $self->{max_size}) {
    flock($fh, LOCK_UN); close $fh;
    return (undef, 'size cap exceeded');
  }
  seek($fh, $current, 0) or do {
    my $e = $!; flock($fh, LOCK_UN); close $fh;
    return (undef, "seek: $e");
  };
  my $written = 0;
  while ($written < length($remaining)) {
    my $n = syswrite($fh, $remaining, length($remaining) - $written,
      $written);
    if (!defined $n || $n == 0) {
      my $e = $! || 'short write';
      flock($fh, LOCK_UN); close $fh;
      return (undef, "write: $e");
    }
    $written += $n;
  }
  my $new_size = $current + $written;

  # Keep the row in sync before another worker can acquire the file lock.
  # A replay also repairs a stale row left by an interrupted DB update.
  my $updated = eval {
    $self->{db}->do_(
      'UPDATE upload_sessions SET size=? WHERE id=?', $new_size, $id);
    1;
  };
  my $db_err = $@;
  flock($fh, LOCK_UN);
  close $fh;
  return (undef, "database: $db_err") unless $updated;
  return ($new_size, undef);
}

# Mark the session as finalized so further appends are refused.
# Doesn't move or delete the file; the consuming handler takes care
# of that via claim() + cleanup().
sub finalize {
  my ($self, $id, $sid) = @_;
  my $row = $self->_row($id);
  return (0, 'unknown upload') unless $row;
  return (0, 'not your upload') unless $row->{sid} eq $sid;
  $self->{db}->do_(
    q{UPDATE upload_sessions SET finalized_at = strftime('%s','now')
        WHERE id=?}, $id);
  return ($row->{size}, undef);
}

# Look up a finalized upload and return its on-disk path. Verifies
# $sid binding so a stolen upload_id alone is useless.
sub claim {
  my ($self, $id, $sid) = @_;
  my $row = $self->_row($id);
  return (undef, 'unknown upload') unless $row;
  return (undef, 'not your upload') unless $row->{sid} eq $sid;
  return (undef, 'not finalized')   unless $row->{finalized_at};
  my $path = $self->_path_for($id);
  return (undef, 'file missing')    unless -f $path;
  return ($path, undef);
}

# Drop the file and the row. Safe to call multiple times. Callers
# invoke this after a successful import or to abort a session.
sub cleanup {
  my ($self, $id, $sid) = @_;
  my $row = $self->_row($id);
  return unless $row;
  return if defined $sid && $row->{sid} ne $sid;
  unlink $self->_path_for($id);
  $self->{db}->do_('DELETE FROM upload_sessions WHERE id=?', $id);
}

sub size_of {
  my ($self, $id, $sid) = @_;
  my $row = $self->_row($id);
  return undef unless $row;
  return undef if defined $sid && $row->{sid} ne $sid;
  return $row->{size};
}

1;
