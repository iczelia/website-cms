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

package Iczelia::Handlers::Static;
use strict;
use warnings;
use File::Spec    ();
use Cwd           ();
use Iczelia::HTTP ();

use constant MAX_STATIC_BYTES => 50 * 1024 * 1024;

# Static file handler for chrome (CSS, JS, fonts, images, vendored
# assets). Used in both dev and production; nginx fronts the daemon
# as a blanket proxy_cache rather than serving these itself.

my %CT = (
  'css'         => 'text/css; charset=utf-8',
  'js'          => 'application/javascript; charset=utf-8',
  'json'        => 'application/json',
  'png'         => 'image/png',
  'jpg'         => 'image/jpeg',
  'jpeg'        => 'image/jpeg',
  'gif'         => 'image/gif',
  'svg'         => 'image/svg+xml',
  'webp'        => 'image/webp',
  'avif'        => 'image/avif',
  'ico'         => 'image/x-icon',
  'woff'        => 'font/woff',
  'woff2'       => 'font/woff2',
  'ttf'         => 'font/ttf',
  'otf'         => 'font/otf',
  'eot'         => 'application/vnd.ms-fontobject',
  'txt'         => 'text/plain; charset=utf-8',
  'xml'         => 'application/xml',
  'webmanifest' => 'application/manifest+json',
  'mp4'         => 'video/mp4',
  'webm'        => 'video/webm',
  'ogg'         => 'audio/ogg',
  'oga'         => 'audio/ogg',
  'ogv'         => 'video/ogg',
  'mp3'         => 'audio/mpeg',
  'wav'         => 'audio/wav',
  'pdf'         => 'application/pdf',
);

sub register {
  my ($class, $router, $ctx) = @_;
  my $cfg    = $ctx->{cfg};
  my $share  = $cfg->{'share-dir'};
  my $chrome = $cfg->{'chrome-dir'};
  my $media  = $cfg->{'media-dir'};

  # Resolve roots once so each route is confined to its real
  # filesystem prefix (defeats symlink-out-of-tree attacks).
  my $r_share_web    = Cwd::abs_path("$share/web");
  my $r_share_vendor = Cwd::abs_path("$share/web/vendor");
  my $r_chrome       = Cwd::abs_path($chrome);
  my $r_media        = Cwd::abs_path($media) // do {

    # Media dir may not exist on first boot.
    File::Spec->rel2abs($media);
  };

  $router->get('/cms.css', sub {_serve_safe($r_share_web, "cms.css")});
  $router->get('/cms.js',  sub {_serve_safe($r_share_web, "cms.js")});
  $router->get(
    '/vendor/*rest',
    sub {
      my $req = shift;
      _serve_safe($r_share_vendor, $req->{caps}{rest});
    }
  );

  # Visual chrome: CSS, fonts, asset packs.
  for my $pat (
    qw(
    /assets-1024x768/*rest
    /assets-800x600/*rest
    /assets-600x400/*rest
    /assets-about/*rest
    /fonts/*rest
    )
    )
  {
    my ($prefix)      = $pat =~ m{^/([^/]+)};
    my $is_image_pack = $prefix =~ /^assets-/;
    $router->get(
      $pat,
      sub {
        my $req = shift;
        my $rel = "$prefix/" . $req->{caps}{rest};
        return _serve_safe($r_chrome, $rel) unless $is_image_pack;
        return _serve_image_pick($r_chrome, $rel, $req);
      }
    );
  }

  # Root-level CSS files referenced directly by the chrome.
  $router->get('/common.compat.css',
    sub {_serve_safe($r_chrome, "common.compat.css")});
  $router->get('/style.mobile.compat.css',
    sub {_serve_safe($r_chrome, "style.mobile.compat.css")});
  $router->get('/style.600.compat.css',
    sub {_serve_safe($r_chrome, "style.600.compat.css")});
  $router->get('/style.800.compat.css',
    sub {_serve_safe($r_chrome, "style.800.compat.css")});
  $router->get('/style.1024.compat.css',
    sub {_serve_safe($r_chrome, "style.1024.compat.css")});
  $router->get('/about.compat.css',
    sub {_serve_safe($r_chrome, "about.compat.css")});

  # Uploaded media. Stray SVGs (uploaded directly into the dir) are
  # served as text/plain so the browser can't execute embedded script.
  $router->get(
    '/media/*rest',
    sub {
      my $req = shift;
      my $rel = $req->{caps}{rest};
      return _bad_path() if !defined $rel || $rel =~ m{(?:^|/)\.\.(?:/|$)};
      if ($rel =~ /\.svg$/i) {
        return _serve_safe($r_media, $rel,
          force_ct => 'text/plain; charset=utf-8');
      }
      _serve_safe($r_media, $rel);
    }
  );

  $router->get(
    '/favicon.ico',
    sub {
      _serve_safe($r_chrome, "assets-1024x768/iczelia-128.png");
    }
  );

  # PGP public key. Admin uploads via /admin/pgp/ atomically rewrite
  # this file; we serve it back on /pub.pgp, 404 when not present.
  my $var_dir = _var_dir_of($cfg);
  $router->get(
    '/pub.pgp',
    sub {
      my $path = "$var_dir/pub.pgp";
      return Iczelia::HTTP::error(404) unless -f $path && -r $path;
      open my $fh, '<:raw', $path or return Iczelia::HTTP::error(500);
      local $/;
      my $body = <$fh>;
      close $fh;
      return {
        status  => 200,
        headers => {
          'Content-Type'  => 'application/pgp-keys',
          'Cache-Control' => 'public, max-age=600',
        },
        body => $body,
      };
    }
  );
}

sub _bad_path {Iczelia::HTTP::error(400, 'bad path')}

# Mutable per-instance state dir (db, cookie-secret, pgp pubkey, ...),
# derived from the configured db path.
sub _var_dir_of {
  my ($cfg) = @_;
  my $p = $cfg->{db};
  $p =~ s{[^/]+\z}{};
  $p =~ s{/+\z}{};
  return $p;
}

# Extension-less chrome image: serve .avif if the UA accepts it and a
# sibling exists, else fall back to the original raster (.png/.gif).
# Vary: Accept so the edge cache splits.
sub _serve_image_pick {
  my ($root, $rel, $req) = @_;
  if ($rel =~ /\.[a-z0-9]+$/i) {
    my $r = _serve_safe($root, $rel);
    _stamp_vary_accept($r);
    return $r;
  }
  my $accept = ($req->{headers}{accept} // '');
  my @tries
    = $accept =~ m{image/avif}i
    ? ("$rel.avif", "$rel.png", "$rel.gif")
    : ("$rel.png", "$rel.gif");
  for my $cand (@tries) {
    my $r = _serve_safe($root, $cand);
    if (($r->{status} // 0) == 200) {
      _stamp_vary_accept($r);
      return $r;
    }
  }
  return Iczelia::HTTP::error(404);
}

sub _stamp_vary_accept {
  my ($r) = @_;
  return unless $r && ref $r eq 'HASH';
  $r->{headers} ||= {};
  my $v = $r->{headers}{Vary};
  $r->{headers}{Vary} = defined $v && length $v ? "$v, Accept" : 'Accept';
}

# Serve $root/$rel only if it resolves (after symlinks) to something
# still inside $root. Defeats both ../ traversal and symlink escape.
sub _serve_safe {
  my ($root, $rel, %opt) = @_;
  return Iczelia::HTTP::error(404) unless defined $root && defined $rel;
  return _bad_path() if $rel =~ m{(?:^|/)\.\.(?:/|$)};
  return _bad_path() if $rel =~ m{\0};
  my $full     = File::Spec->catfile($root, $rel);
  my $resolved = Cwd::abs_path($full);
  return Iczelia::HTTP::error(404) unless defined $resolved;
  my $prefix = $root;
  $prefix .= '/' unless $prefix =~ m{/$};
  return _bad_path()
    unless index($resolved, $prefix) == 0
    || $resolved eq $root;
  return _serve_file($resolved, %opt);
}

sub _serve_file {
  my ($path, %opt) = @_;
  return Iczelia::HTTP::error(404) unless -f $path && -r $path;
  my $size = -s $path;
  return Iczelia::HTTP::error(413)
    if defined $size && $size > MAX_STATIC_BYTES;
  open my $fh, '<:raw', $path or return Iczelia::HTTP::error(500);
  local $/;
  my $body = <$fh>;
  close $fh;
  my ($ext) = $path =~ /\.([^.\/]+)$/;
  my $ct = $opt{force_ct} || $CT{lc($ext // '')} || 'application/octet-stream';

  # Cache layer overrides Cache-Control on store; on cache miss the
  # response_cache.put still re-stamps it via _cache_control_for($path).
  return {
    status  => 200,
    headers => {'Content-Type' => $ct},
    body    => $body,
  };
}

1;
