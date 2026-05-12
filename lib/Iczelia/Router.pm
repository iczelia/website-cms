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

package Iczelia::Router;
use strict;
use warnings;

# Path patterns: /literal, /:name (one segment), /*rest (greedy).
# First registration wins. match() returns ($handler, \%caps), or
# (undef, undef, $matched_path) when path matched but method didn't.

sub new {
  my ($class) = @_;
  return bless {routes => []}, $class;
}

sub add {
  my ($self, $method, $pat, $handler) = @_;
  my @caps;
  my @segs = split m{/}, $pat, -1;
  shift @segs if @segs && $segs[0] eq '';
  my @bits;
  for my $seg (@segs) {
    if ($seg =~ /^:(\w+)$/) {
      push @caps, $1;
      push @bits, '([^/]+)';
    }
    elsif ($seg =~ /^\*(\w+)$/) {
      push @caps, $1;
      push @bits, '(.*)';
    }
    else {
      push @bits, quotemeta($seg);
    }
  }
  my $re = '/' . join('/', @bits);
  push @{$self->{routes}},
    {
    method  => uc $method,
    re      => qr{\A$re\z},
    caps    => \@caps,
    handler => $handler,
    };
  return $self;
}

sub get  {my $s = shift; $s->add(GET    => @_)}
sub post {my $s = shift; $s->add(POST   => @_)}
sub put  {my $s = shift; $s->add(PUT    => @_)}
sub del  {my $s = shift; $s->add(DELETE => @_)}

sub match {
  my ($self, $method, $path) = @_;
  $method = uc $method;
  my $matched_path;
  for my $r (@{$self->{routes}}) {
    if (my @m = $path =~ $r->{re}) {
      $matched_path = 1;
      next unless $r->{method} eq $method;
      my %caps;
      @caps{@{$r->{caps}}} = @m if @{$r->{caps}};
      return ($r->{handler}, \%caps);
    }
  }
  return (undef, undef, $matched_path);
}

1;
