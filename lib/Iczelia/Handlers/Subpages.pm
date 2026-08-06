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
use Encode               ();
use Iczelia              ();
use Iczelia::Compress    ();
use Iczelia::HTTP        ();
use Iczelia::Subpages    ();
use Iczelia::Theme       ();
use Iczelia::PublicListing ();
use Iczelia::Util        qw(escape_html escape_url);

# Server fallback (after the router and dynamic pages): claim
# /<slug>/... when <slug> is a static subpage. Returns a response, or
# undef so the next fallback can try.

# max-age=0: an admin edit can bust /<slug>/ at any time, so clients
# revalidate against the ETag instead of holding a copy.
use constant CACHE_CONTROL  => 'public, max-age=0, must-revalidate';
use constant CACHE_MAX_BODY => 2 * 1024 * 1024;

# Cache text only. Media is stored uncompressed and already reads back
# as a single indexed row, so a second copy gains nothing.
sub _cacheable {
  my ($resp) = @_;
  my $body = $resp->{body};
  my $ct   = $resp->{headers}{'Content-Type'} // '';
  if ( !defined $body
    || length($body) > CACHE_MAX_BODY
    || Iczelia::Compress::is_binary_media_ct($ct))
  {
    $resp->{headers}{'Cache-Control'} = 'no-cache';
    $resp->{_no_cache}                = 1;
    return $resp;
  }
  $resp->{headers}{'Cache-Control'} = CACHE_CONTROL;
  return $resp;
}

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

  if (my $want = Iczelia::Theme::wanted_from_query($req)) {
    return Iczelia::Theme::apply_response($req, $want);
  }

  if (!defined $rest) {
    return _redirect("/$slug/", $req);
  }

  my $is_dir_req = ($rest eq '/' || $rest =~ m{/\z});
  my $rel = $rest;
  $rel =~ s{^/}{};
  $rel .= 'index.html' if $is_dir_req;
  my $clean = Iczelia::Subpages::sanitize_rel_path($rel);
  return Iczelia::HTTP::error(404) unless defined $clean;

  # Prefer a precompressed .br/.gz sibling (brotli_static / gzip_static).
  # HTML is excluded so the daemon's minify pass never meets an encoded body.
  # Uncached: the cache holds one identity body per path, so a br hit
  # would go to a client that asked for gzip.
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

  if (!$file && !$is_dir_req) {
    # A directory addressed without its trailing slash.
    return _redirect("$path/", $req)
      if Iczelia::Subpages::file($ctx->db, $sp->{id}, "$clean/index.html");
  }

  if (!$file && $is_dir_req && $sp->{listing}) {
    return _render_listing($ctx, $sp, $rest, $req);
  }

  return Iczelia::HTTP::error(404) unless $file;

  return _cacheable(
    {
      status  => 200,
      headers => {'Content-Type' => $file->{content_type}},
      body    => $file->{content},
    }
  );
}

sub _redirect {
  my ($to, $req) = @_;
  $to .= '?' . $req->{query} if defined $req->{query} && length $req->{query};
  return Iczelia::HTTP::redirect($to, status => 301);
}

# Apache-style directory index for /<slug>/<dir>/ when the subpage has
# the listing toggle on and no index.html exists at that depth. Builds
# row hashes and delegates the actual HTML scaffold to PublicListing so
# the git tree view renders with the identical chrome.
sub _render_listing {
  my ($ctx, $sp, $rest, $req) = @_;
  my $slug = $sp->{slug};
  my $dir  = $rest;
  $dir =~ s{^/}{};
  $dir =~ s{/$}{};

  my $entries = Iczelia::Subpages::directory_entries($ctx->db, $sp->{id}, $dir);

  # The one blob a listing reads whole; same cap.
  my $readme;
  for my $e (@$entries) {
    next if $e->{type} ne 'file';
    next unless Iczelia::Subpages::is_readme_name($e->{name});
    last if ($e->{size} // 0) > Iczelia::Subpages::SNIFF_MAX_SIZE;
    my $row = Iczelia::Subpages::file($ctx->db, $sp->{id}, $e->{path});
    if ($row) {
      my $bytes   = $row->{content};
      my $decoded = eval {
        Encode::decode('UTF-8', $bytes, Encode::FB_CROAK());
      };
      $readme = {
        name    => $e->{name},
        content => (defined $decoded ? $decoded : $bytes),
      };
    }
    last;
  }

  my $url_path = "/$slug/" . (length $dir ? "$dir/" : '');
  my $theme    = Iczelia::Theme::from_cookie($req // {});

  my @rows;
  if (length $dir) {
    push @rows, {
      icon      => 'folder.png',
      name_href => '<a href="../">Parent Directory</a>',
      mtime     => '-',
      size      => '-',
    };
  }
  for my $e (@$entries) {
    my ($icon, $href, $disp, $size);
    if ($e->{type} eq 'dir') {
      $icon = 'folder.png';
      $href = escape_url($e->{name}) . '/';
      $disp = escape_html($e->{name}) . '/';
      $size = '-';
    }
    else {
      $icon = Iczelia::Subpages::icon_for_entry($e->{name},
        content_type => $e->{content_type}, is_binary => $e->{is_binary},
        lang => $e->{lang});
      $href = escape_url($e->{name});
      $disp = escape_html($e->{name});
      $size = Iczelia::Subpages::fmt_size($e->{size});
    }
    push @rows, {
      icon      => $icon,
      name_href => qq{<a href="$href">$disp</a>},
      mtime     => Iczelia::Subpages::fmt_mtime($e->{updated_at}),
      size      => $size,
    };
  }

  return _cacheable(
    {
      status  => 200,
      headers => {
        'Content-Type' => 'text/html; charset=utf-8',
        'Vary'         => 'Cookie',
      },
      body => Iczelia::PublicListing::render_listing(
        title  => "Index of $url_path",
        rows   => \@rows,
        readme => $readme,
        footer => Iczelia::PublicListing::footer_for($ctx->db),
        theme  => $theme,
      ),
    }
  );
}

1;
