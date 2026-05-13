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

package Iczelia::Handlers::Dynamic;
use strict;
use warnings;
use Iczelia::HTTP ();

# Server::_handle_one calls lookup() when the router has no static match.
# Returns a response (admin-defined dynamic page) or undef (-> 404).

sub lookup {
  my ($ctx, $req) = @_;
  my $path = $req->{path};
  return undef unless defined $path && length $path;
  return undef unless ($req->{method} || 'GET') eq 'GET';
  return undef unless $path =~ m{^/[a-z0-9]};
  my $row =
    $ctx->db->row('SELECT 1 FROM dynamic_pages WHERE route=?', $path);
  return undef unless $row;
  my $html = $ctx->render->render_dynamic($path);
  return undef unless defined $html;
  return Iczelia::HTTP::html($html);
}

1;
