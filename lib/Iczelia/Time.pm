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

package Iczelia::Time;
use strict;
use warnings;
use Exporter qw(import);

# Centralised time/date formatters used across the CMS.

our @EXPORT_OK = qw(fmt_date fmt_iso fmt_ago ts_fmt ts_to_local_input atom_iso clock_string http_date http_date_of);

my @WD = qw(Sun Mon Tue Wed Thu Fri Sat);
my @MN = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

sub fmt_date {
  my $s = shift;
  return '' unless defined $s;
  if ($s =~ /^(\d{4})-(\d{2})-(\d{2})/) {
    return "$2.$3.$1";
  }
  return $s;
}

sub fmt_iso {
  my $epoch = shift;
  return '' unless defined $epoch;
  my @t = gmtime($epoch);
  return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
    $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

sub fmt_ago {
  my $epoch = shift;
  return '' unless defined $epoch;
  my $now = time;
  my $d   = $now - $epoch;
  return 'now'                      if $d < 60;
  return int($d / 60) . 'm ago'     if $d < 60 * 60;
  return int($d / 3600) . 'h ago'   if $d < 60 * 60 * 24;
  return int($d / 86400) . 'd ago'  if $d < 60 * 60 * 24 * 14;
  return int($d / 604800) . 'w ago' if $d < 60 * 60 * 24 * 56;
  my @t = localtime($epoch);
  return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

sub ts_fmt {
  my ($ts) = @_;
  return '' unless defined $ts;
  my @t = localtime $ts;
  return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

sub ts_to_local_input {
  my ($ts) = @_;
  return '' unless defined $ts && length $ts;
  my @t = gmtime $ts;
  return sprintf '%04d-%02d-%02dT%02d:%02d',
    $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1];
}

sub atom_iso {
  my ($ts) = @_;
  my @t = gmtime($ts || time);
  return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
    $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

sub clock_string {
  my @t = gmtime(time);
  return sprintf '%s%d%s%d, %02d:%02d GMT',
    $WD[$t[6]], $t[3], $MN[$t[4]], $t[5] + 1900, $t[2], $t[1];
}

sub http_date {http_date_of(time)}

sub http_date_of {
  my ($t) = @_;
  my @g = gmtime($t);
  return sprintf '%s, %02d %s %d %02d:%02d:%02d GMT',
    $WD[$g[6]], $g[3], $MN[$g[4]], $g[5] + 1900, $g[2], $g[1], $g[0];
}

1;
