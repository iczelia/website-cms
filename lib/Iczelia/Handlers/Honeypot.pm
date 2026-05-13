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

package Iczelia::Handlers::Honeypot;
use strict;
use warnings;
use Iczelia::HTTP ();

# Serves share/bomb.gz, a gzip decompression bomb, on the paths
# robots.txt disallows (see Iczelia::Handlers::Feeds::_robots).
our @PATHS = ('/wp-admin', '/.env');

my $BOMB;

sub register {
  my ($class, $router, $ctx) = @_;
  $BOMB = _load_bomb($ctx->cfg->{'share-dir'}) unless defined $BOMB;
  $router->get($_, \&_serve) for @PATHS;
}

sub _serve {
  return Iczelia::HTTP::error(404) unless defined $BOMB;
  return {
    status  => 200,
    headers => {
      'Content-Type'     => 'text/html; charset=utf-8',
      'Content-Encoding' => 'gzip',
    },
    body      => $BOMB,
    _no_cache => 1,
  };
}

sub _load_bomb {
  my ($share) = @_;
  return undef unless defined $share && length $share;
  open my $fh, '<:raw', "$share/bomb.gz" or return undef;
  local $/;
  my $body = <$fh>;
  close $fh;
  return defined $body && length $body ? $body : undef;
}

1;
