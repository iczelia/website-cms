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

package Iczelia::CachePolicy;
use strict;
use warnings;
use Exporter qw(import);

# Two distinct path-pattern policies used by the cache layer:
#
#   bypass_for_request($req)
#     Daemon-cache eligibility. Returns 1 to skip both Cache::get and
#     Cache::put for this request. Per-response opt-outs live on the
#     response itself (the `_no_cache` flag honoured in
#     Iczelia::Server::_handle_one); the patterns here are structural
#     bypasses for paths whose contents always vary per request and so
#     don't even warrant a cache lookup.
#
#   cache_control_for($path)
#     HTTP response-header policy. Returned value goes into the
#     `Cache-Control` header stamped on cache hits and stores. Decides
#     how long upstream caches (browser, nginx) hold the response.
#
# Both predicates live here so the path-pattern knowledge is in one
# place. They share no state beyond the patterns themselves.

our @EXPORT_OK = qw(bypass_for_request cache_control_for);

sub bypass_for_request {
  my ($req) = @_;
  return 1 unless $req->{method} eq 'GET' || $req->{method} eq 'HEAD';
  return 1 if length($req->{query} // '');
  my $path = $req->{path};
  return 1 unless defined $path && length $path;

  # Authenticated admin: never cache.
  return 1 if $path =~ m{^/admin/?};
  return 1 if $path =~ m{^/login/?$};
  return 1 if $path =~ m{^/logout/?$};

  # Home embeds a live GMT clock; caching would freeze it.
  return 1 if $path eq '/';

  # Guestbook embeds a per-visitor anon-CSRF token bound to a cookie;
  # caching would leak one user's token to everyone else.
  return 1 if $path =~ m{^/guestbook/?$};
  return 1 if $req->{cookies} && exists $req->{cookies}{iczelia_sid};

  # Chrome image packs dispatch avif/png by Accept and emit Vary: Accept.
  # The internal cache keys by path alone and stamps a fixed Vary, so
  # leave it to nginx (which honours Vary) to split these.
  return 1
    if $path =~ m{^/assets-(?:1024x768|800x600|600x400|about)/};
  return 0;
}

# Static assets (CSS, JS, images, fonts) get aggressive caching; every
# other path is HTML / feed content that may change on any admin edit,
# so we serve no-store and rely on the daemon's own response_cache for
# repeat hits.
sub cache_control_for {
  my ($path) = @_;
  return 'public, max-age=31536000, immutable'
    if $path =~ m{^/(?:vendor/|fonts/|assets-)};
  return 'public, max-age=86400'
    if $path =~ m{^/(?:media/|favicon\.ico\z)};
  return 'public, max-age=3600'
    if $path =~ m{^/(?:cms\.(?:css|js)|style\.|about\.compat\.css|common\.compat\.css)};
  return 'public, max-age=600' if $path eq '/pub.pgp';
  return 'no-store';
}

1;
