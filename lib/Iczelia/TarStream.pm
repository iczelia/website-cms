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

package Iczelia::TarStream;
use strict;
use warnings;
use Carp qw(croak);

# Minimal streaming USTAR writer. Emits headers + data + padding
# through a caller-supplied `write` coderef, so backups can pipe
# straight into an HTTP chunked response without ever buffering the
# whole archive. Long names (>100 bytes) ride on a GNU long-name
# (typeflag 'L') prefix entry; everything else stays plain ustar so
# `tar -xf` reads it without flags.
#
# Not a full Archive::Tar replacement: no compression, no extraction,
# no extended attributes, no per-entry modes beyond regular-file/0644.
# We use Archive::Tar's iter() for *imports* (richer + battle-tested);
# this module only handles the export path.

use constant BLOCK => 512;

sub new {
  my ($class, %arg) = @_;
  my $w = $arg{write};
  croak "write coderef required" unless ref($w) eq 'CODE';
  return bless {
    write => $w,
    closed => 0,
  }, $class;
}

# add_data($name, $bytes, %opt)
#   mtime => epoch (defaults to now)
#   mode  => octal file mode (defaults to 0644)
# Emits header + payload + zero-pad to the next 512B block.
sub add_data {
  my ($self, $name, $bytes, %opt) = @_;
  croak "writer closed" if $self->{closed};
  $bytes = '' unless defined $bytes;
  my $size  = length $bytes;
  my $mtime = defined $opt{mtime} ? $opt{mtime} : time;
  my $mode  = defined $opt{mode}  ? $opt{mode}  : 0644;
  $self->_emit_header($name, $size, $mtime, $mode, '0');
  $self->{write}->($bytes) if $size;
  my $pad = (BLOCK - ($size % BLOCK)) % BLOCK;
  $self->{write}->("\0" x $pad) if $pad;
}

# add_fh($name, $fh, $size, %opt)
#   Stream from a filehandle in 64 KB chunks. $size MUST match the
#   actual bytes available -- callers stat() the file first to lock
#   the size into the tar header before reading. A short read pads
#   the tail with NULs so the archive structurally validates even on
#   a truncation race.
sub add_fh {
  my ($self, $name, $fh, $size, %opt) = @_;
  croak "writer closed" if $self->{closed};
  croak "size required" unless defined $size;
  my $mtime = defined $opt{mtime} ? $opt{mtime} : time;
  my $mode  = defined $opt{mode}  ? $opt{mode}  : 0644;
  $self->_emit_header($name, $size, $mtime, $mode, '0');

  my $remaining = $size;
  my $buf;
  while ($remaining > 0) {
    my $want = $remaining > 65536 ? 65536 : $remaining;
    my $n = sysread($fh, $buf, $want);
    if (!defined $n) {
      $self->{write}->("\0" x $remaining);
      last;
    }
    if ($n == 0) {
      $self->{write}->("\0" x $remaining);
      last;
    }
    $self->{write}->($buf);
    $remaining -= $n;
  }
  my $pad = (BLOCK - ($size % BLOCK)) % BLOCK;
  $self->{write}->("\0" x $pad) if $pad;
}

# End-of-archive marker: two zero blocks.
sub finish {
  my ($self) = @_;
  return if $self->{closed};
  $self->{write}->("\0" x (BLOCK * 2));
  $self->{closed} = 1;
}

sub _emit_header {
  my ($self, $name, $size, $mtime, $mode, $typeflag) = @_;
  if (length($name) > 100) {
    $self->_emit_long_name($name);
  }
  my $hdr = _build_header($name, $size, $mtime, $mode, $typeflag);
  $self->{write}->($hdr);
}

# GNU long-name prefix entry: typeflag 'L', name '././@LongLink',
# size = length($name)+1, payload is the full name + NUL, padded.
sub _emit_long_name {
  my ($self, $name) = @_;
  my $payload = $name . "\0";
  my $hdr = _build_header('././@LongLink',
    length($payload), 0, 0, 'L');
  $self->{write}->($hdr);
  $self->{write}->($payload);
  my $pad = (BLOCK - (length($payload) % BLOCK)) % BLOCK;
  $self->{write}->("\0" x $pad) if $pad;
}

# 512-byte USTAR header. Truncates long names to 100 bytes (the
# caller is expected to have already emitted a GNU 'L' prefix entry
# with the real path).
sub _build_header {
  my ($name, $size, $mtime, $mode, $typeflag) = @_;
  $typeflag //= '0';
  my $short_name = length($name) > 100 ? substr($name, 0, 100) : $name;

  my @fields = (
    _str($short_name, 100),
    _num($mode  & 07777, 8),
    _num(0,               8),       # uid
    _num(0,               8),       # gid
    _num($size,          12),
    _num($mtime,         12),
    '        ',                     # chksum placeholder
    $typeflag,
    _str('', 100),                  # linkname
    "ustar\0",                      # magic
    '00',                           # version
    _str('', 32),                   # uname
    _str('', 32),                   # gname
    _num(0, 8),                     # devmajor
    _num(0, 8),                     # devminor
    _str('', 155),                  # prefix
    "\0" x 12,                      # pad to 512
  );
  my $hdr = join '', @fields;
  $hdr .= "\0" x (BLOCK - length $hdr) if length($hdr) < BLOCK;
  $hdr   = substr($hdr, 0, BLOCK);

  # Unsigned-byte checksum, computed with the 8-byte chksum field
  # treated as ASCII spaces. POSIX permits 6 octal digits + NUL +
  # space; we use that fixed format.
  my $sum = 0;
  $sum += ord(substr($hdr, $_, 1)) for 0 .. BLOCK - 1;
  substr($hdr, 148, 8) = sprintf('%06o', $sum) . "\0 ";
  return $hdr;
}

sub _str {
  my ($s, $len) = @_;
  $s = '' unless defined $s;
  if (length($s) >= $len) {
    return substr($s, 0, $len);
  }
  return $s . ("\0" x ($len - length $s));
}

# Octal field: $len-1 zero-padded digits, terminated with a NUL.
sub _num {
  my ($n, $len) = @_;
  $n = 0 unless defined $n && $n >= 0;
  return sprintf("%0*o", $len - 1, $n) . "\0";
}

1;
