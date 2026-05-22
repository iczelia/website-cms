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

package Iczelia::Handlers::Subpages;
use strict;
use warnings;
use Iczelia::HTTP     ();
use Iczelia::Subpages ();

# Server fallback (after the router and dynamic pages): claim
# /<slug>/... when <slug> is a static subpage. Returns a response, or
# undef so the next fallback can try.

sub serve {
  my ($ctx, $req) = @_;
  my $path = $req->{path};
  return undef unless defined $path && length $path;
  my $m = $req->{method} || 'GET';
  return undef unless $m eq 'GET' || $m eq 'HEAD';

  my ($slug, $rest) = $path =~ m{^/([a-z0-9][a-z0-9-]*)(/.*)?\z}
    or return undef;
  my $sp = Iczelia::Subpages::get_by_slug($ctx->db, $slug)
    or return undef;

  # Bare /<slug> canonicalises to /<slug>/.
  if (!defined $rest) {
    return _redirect("/$slug/", $req);
  }

  my $rel = $rest;
  $rel =~ s{^/}{};
  $rel .= 'index.html' if $rel eq '' || $rel =~ m{/\z};
  my $clean = Iczelia::Subpages::sanitize_rel_path($rel);
  return Iczelia::HTTP::error(404) unless defined $clean;

  # Prefer a precompressed .br/.gz sibling (brotli_static / gzip_static).
  # HTML is excluded so the daemon's minify pass never meets an encoded body.
  my $ct = Iczelia::Subpages::content_type_for($clean);
  if ($ct !~ m{^text/html\b}i) {
    my $ae = $req->{headers}{'accept-encoding'} // '';
    for my $cand (['br', '.br', qr/\bbr\b/i], ['gzip', '.gz', qr/\bgzip\b/i]) {
      next unless $ae =~ $cand->[2];
      my $pre =
        Iczelia::Subpages::file($ctx->db, $sp->{id}, "$clean$cand->[1]");
      next unless $pre;
      return {
        status  => 200,
        headers => {
          'Content-Type'     => $ct,
          'Content-Encoding' => $cand->[0],
          'Vary'             => 'Accept-Encoding',
          'Cache-Control'    => 'no-cache',
        },
        body      => $pre->{content},
        _no_cache => 1,
      };
    }
  }

  my $file = Iczelia::Subpages::file($ctx->db, $sp->{id}, $clean);
  if (!$file && $rest !~ m{/\z}) {
    # A directory addressed without its trailing slash.
    return _redirect("$path/", $req)
      if Iczelia::Subpages::file($ctx->db, $sp->{id}, "$clean/index.html");
  }
  return Iczelia::HTTP::error(404) unless $file;

  return {
    status  => 200,
    headers => {
      'Content-Type'  => $file->{content_type},
      'Cache-Control' => 'no-cache',
    },
    body      => $file->{content},
    _no_cache => 1,
  };
}

sub _redirect {
  my ($to, $req) = @_;
  $to .= '?' . $req->{query} if defined $req->{query} && length $req->{query};
  return Iczelia::HTTP::redirect($to, status => 301);
}

1;
