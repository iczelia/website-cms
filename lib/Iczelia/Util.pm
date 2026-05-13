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

package Iczelia::Util;
use strict;
use warnings;
use Exporter qw(import);
use Encode   ();

our @EXPORT_OK = qw(
  escape_html escape_attr escape_url
  slugify trim
  excerpt
  detect_cores
);

# /proc/cpuinfo CPU count, falling back to 1.
sub detect_cores {
  my $n = 0;
  if (open my $fh, '<', '/proc/cpuinfo') {
    while (my $line = <$fh>) {$n++ if $line =~ /^processor\s*:/}
    close $fh;
  }
  return $n > 0 ? $n : 1;
}

sub escape_html {
  my $s = shift;
  return '' unless defined $s;
  $s =~ s/&/&amp;/g;
  $s =~ s/</&lt;/g;
  $s =~ s/>/&gt;/g;
  $s =~ s/"/&quot;/g;
  $s =~ s/'/&#39;/g;
  return $s;
}

sub escape_attr {goto &escape_html}

sub escape_url {
  my $s = shift;
  return '' unless defined $s;
  $s = Encode::encode('UTF-8', $s) if Encode::is_utf8($s);
  $s =~ s/([^A-Za-z0-9\-._~])/sprintf '%%%02X', ord $1/ge;
  return $s;
}

sub slugify {
  my $s = shift;
  return _empty_slug() unless defined $s;
  $s = lc $s;
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+|-+$//g;
  $s = substr($s, 0, 80) if length($s) > 80;
  return _empty_slug() unless length $s;
  return $s;
}

sub _empty_slug {
  return 'untitled-' . sprintf('%x', time());
}

sub trim {
  my $s = shift;
  return '' unless defined $s;
  $s =~ s/^\s+//;
  $s =~ s/\s+$//;
  return $s;
}

sub excerpt {
  my ($s, $n) = @_;
  $n ||= 200;
  return '' unless defined $s;
  $s =~ s/<[^>]+>//g;
  $s =~ s/\s+/ /g;
  $s = trim($s);
  if (length($s) > $n) {
    $s = substr($s, 0, $n);
    $s =~ s/\s+\S*$//;
    $s .= '...';
  }
  return $s;
}

1;
