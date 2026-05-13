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

package Iczelia::Context;
use strict;
use warnings;
use Carp qw(croak);

# Application context handed to every handler. Replaces the previous
# untyped hashref so the available services are discoverable, lazy
# helpers have a home, and accidental typos in slot names are caught.
#
# All slots are read-only after construction; lazy services
# (guestbook throttles) populate themselves on first access.
#
# Constructor accepts a hash of named services and returns a blessed
# instance. Handlers access them via accessor methods: $ctx->db,
# $ctx->render, $ctx->auth, etc.

# Core slots, populated by Iczelia::App::build. Tests may construct a
# subset for narrow unit-test scope; accessors return undef for unset
# slots so test fixtures don't need to mint stubs for unused services.
my @CORE_SLOTS = qw(cfg db template render auth cache fetcher schema content);

sub new {
  my ($class, %arg) = @_;
  my %self;
  $self{$_} = $arg{$_} for @CORE_SLOTS;
  return bless \%self, $class;
}

sub cfg      {$_[0]->{cfg}}
sub db       {$_[0]->{db}}
sub template {$_[0]->{template}}
sub render   {$_[0]->{render}}
sub auth     {$_[0]->{auth}}
sub cache    {$_[0]->{cache}}
sub fetcher  {$_[0]->{fetcher}}
sub schema   {$_[0]->{schema}}
sub content  {$_[0]->{content}}

# Guestbook throttles. Lazy because they're only relevant to the
# guestbook handler. Defined here so the slot inventory stays in one
# file rather than being patched onto $ctx by Handlers/Guestbook.
sub gb_throttle_short {
  my ($self) = @_;
  $self->{gb_throttle_short} ||= do {
    require Iczelia::Throttle;
    Iczelia::Throttle->new(
      db     => $self->{db},
      table  => 'guestbook_throttle',
      max    => 1,
      window => 5 * 60,                 # 1 per IP per 5 min
    );
  };
}

sub gb_throttle_day {
  my ($self) = @_;
  $self->{gb_throttle_day} ||= do {
    require Iczelia::Throttle;
    Iczelia::Throttle->new(
      db     => $self->{db},
      table  => 'guestbook_throttle',
      max    => 5,
      window => 24 * 60 * 60,           # 5 per IP per 24h
    );
  };
}

1;
