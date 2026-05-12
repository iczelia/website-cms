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

package Iczelia::Throttle;
use strict;
use warnings;
use Carp qw(croak);

# Per-IP fixed-window rate limit. allow() is atomic across workers
# (BEGIN IMMEDIATE); check_only() probes without consuming.

sub new {
  my ($class, %arg) = @_;
  croak "db required"    unless $arg{db};
  croak "table required" unless $arg{table};
  return bless {
    db     => $arg{db},
    table  => $arg{table},
    max    => $arg{max}    || 4,
    window => $arg{window} || 60,
  }, $class;
}

sub allow      {my ($self, $ip) = @_; $self->_check($ip, count => 1)}
sub check_only {my ($self, $ip) = @_; $self->_check($ip, count => 0)}

sub _check {
  my ($self, $ip, %opt) = @_;
  return 0 unless defined $ip && length $ip;
  my $T   = $self->{table};
  my $now = time;
  my $win = $self->{window};
  my $max = $self->{max};

  return $self->{db}->tx_immediate(
    sub {
      my $d = shift;
      my $row =
        $d->row("SELECT attempts, window_start FROM $T WHERE ip=?", $ip);
      if (!$row) {
        $d->do_("INSERT INTO $T(ip, attempts, window_start) VALUES(?, 1, ?)",
          $ip, $now)
          if $opt{count};
        return 1;
      }
      if ($now - ($row->{window_start} || 0) > $win) {
        $d->do_("UPDATE $T SET attempts=1, window_start=? WHERE ip=?",
          $now, $ip)
          if $opt{count};
        return 1;
      }
      return 0 if ($row->{attempts} || 0) >= $max;
      $d->do_("UPDATE $T SET attempts=attempts+1 WHERE ip=?", $ip)
        if $opt{count};
      return 1;
    }
  );
}

sub reset_ip {
  my ($self, $ip) = @_;
  $self->{db}->do_("DELETE FROM $self->{table} WHERE ip=?", $ip);
}

sub gc {
  my ($self) = @_;
  my $cutoff = time - 2 * $self->{window};
  $self->{db}
    ->do_("DELETE FROM $self->{table} WHERE window_start < ?", $cutoff);
}

1;
