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
use Encode            ();
use Iczelia           ();
use Iczelia::HTTP     ();
use Iczelia::Subpages ();
use Iczelia::Util     qw(escape_html escape_url);

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

  if (my $want = _wanted_theme($req)) {
    return _set_theme_response($req, $want);
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

# Theme persistence without JavaScript:
#   * cookie `iczelia_theme` (light|dark, missing = auto/system)
#   * `?set-theme=light|dark|auto` writes the cookie and 303-redirects
#     back to the clean URL so the next render picks up the new value.

use constant THEME_COOKIE => 'iczelia_theme';

sub _theme_from_cookie {
  my ($req) = @_;
  my $v = $req->{cookies} && $req->{cookies}{+THEME_COOKIE};
  return $v && ($v eq 'light' || $v eq 'dark') ? $v : 'auto';
}

sub _wanted_theme {
  my ($req) = @_;
  my $v = $req->{qparams} && $req->{qparams}{'set-theme'};
  return undef unless defined $v;
  return undef unless $v eq 'light' || $v eq 'dark' || $v eq 'auto';
  return $v;
}

sub _set_theme_response {
  my ($req, $value) = @_;
  my %c = (
    name     => THEME_COOKIE,
    path     => '/',
    samesite => 'Lax',
  );
  if ($value eq 'auto') {
    $c{value}   = '';
    $c{max_age} = 0;
  }
  else {
    $c{value}   = $value;
    $c{max_age} = 60 * 60 * 24 * 365;
  }
  $c{secure} = 1 if Iczelia::HTTP::is_https($req);
  my $resp = Iczelia::HTTP::redirect($req->{path}, status => 303);
  $resp->{cookies}   = [Iczelia::HTTP::make_cookie(%c)];
  $resp->{_no_cache} = 1;
  return $resp;
}

# Apache-style directory index for /<slug>/<dir>/ when the subpage has
# the listing toggle on and no index.html exists at that depth.
sub _render_listing {
  my ($ctx, $sp, $rest, $req) = @_;
  my $slug = $sp->{slug};
  my $dir  = $rest;
  $dir =~ s{^/}{};
  $dir =~ s{/$}{};

  my $entries = Iczelia::Subpages::directory_entries($ctx->db, $sp->{id}, $dir);

  my $readme;
  for my $e (@$entries) {
    next if $e->{type} ne 'file';
    next unless Iczelia::Subpages::is_readme_name($e->{name});
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
  my $theme    = _theme_from_cookie($req // {});
  return {
    status  => 200,
    headers => {
      'Content-Type'  => 'text/html; charset=utf-8',
      'Cache-Control' => 'no-cache',
      'Vary'          => 'Cookie',
    },
    body => _listing_html($url_path, $dir, $entries, $readme,
      _footer_for($ctx->db), $theme),
    _no_cache => 1,
  };
}

sub _footer_for {
  my ($db) = @_;
  my $author = $db->setting('site.author') // 'Kamila Szewczyk';
  my $handle = $db->setting('site.title')  // 'iczelia';
  my $email  = $db->setting('site.email');
  my $start  = $db->setting('site.copyright_start') // 2019;
  my $year   = (gmtime)[5] + 1900;
  my $line   = "copyright (c) $start - $year, $author ($handle)";
  $line .= ", $email" if defined $email && length $email;
  my $ver = $Iczelia::VERSION // '0.1';
  return "$line | iczelia cms v$ver";
}

sub _listing_html {
  my ($url_path, $dir, $entries, $readme, $footer, $theme) = @_;
  $theme //= 'auto';
  my $title   = "Index of $url_path";
  my $esc_ttl = escape_html($title);
  my $html_class = $theme eq 'light' ? ' class="t-light"'
                 : $theme eq 'dark'  ? ' class="t-dark"'
                 :                     '';

  my @rows;
  if (length $dir) {
    push @rows,
        '<tr><td class="icon"><img src="/cms-icons/folder.png" alt=""></td>'
      . '<td class="name"><a href="../">Parent Directory</a></td>'
      . '<td class="mtime">-</td><td class="size">-</td></tr>';
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
      $icon = Iczelia::Subpages::icon_for($e->{name});
      $href = escape_url($e->{name});
      $disp = escape_html($e->{name});
      $size = Iczelia::Subpages::fmt_size($e->{size});
    }
    my $mtime = Iczelia::Subpages::fmt_mtime($e->{updated_at});
    push @rows,
        qq{<tr><td class="icon"><img src="/cms-icons/$icon" alt=""></td>}
      . qq{<td class="name"><a href="$href">$disp</a></td>}
      . qq{<td class="mtime">$mtime</td><td class="size">$size</td></tr>};
  }
  my $row_html = join "\n", @rows;

  my $readme_html = '';
  if ($readme) {
    my $name = escape_html($readme->{name});
    my $body = escape_html($readme->{content});
    $readme_html =
        qq{<section class="readme"><h2>$name</h2>}
      . qq{<pre><code>$body</code></pre></section>\n};
  }
  my $esc_footer  = escape_html($footer // '');
  my $toggle_html = _theme_toggle_html($theme);
  my $dark_auto   = _dark_rules('  html:not(.t-light)');
  my $dark_forced = _dark_rules('html.t-dark');

  return <<"HTML";
<!DOCTYPE html>
<html lang="en"$html_class>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="color-scheme" content="light dark">
<title>$esc_ttl</title>
<style>
body { font-family: Arial, sans-serif; color: #000; background: #fff;
       margin: 16px 24px; max-width: 820px; }
h1 { font-size: 18px; margin: 0 0 12px; font-weight: bold; }
table { border-collapse: collapse; width: 100%; }
thead th { text-align: left; padding: 4px 8px;
           border-bottom: 1px solid #888; background: #eee;
           font-weight: bold; font-size: 12px; }
tbody td { padding: 4px 8px; border-bottom: 1px solid #eee;
           vertical-align: middle; font-size: 13px; }
tbody tr:hover { background: #f5f5f5; }
td.icon { width: 36px; }
td.icon img { height: 28px; vertical-align: middle; border: 0; }
td.size, td.mtime { text-align: right; white-space: nowrap; color: #555; }
td.mtime { font-size: 12px; }
thead th.size, thead th.mtime { text-align: right; }
a { color: #1a3a7a; text-decoration: none; }
a:hover { color: #4a6da7; text-decoration: underline; }
.readme { background: #fafafa; border: 1px solid #ccc;
          padding: 8px 12px; margin: 0 0 14px; }
.readme h2 { margin: 0 0 6px; font-size: 13px; font-weight: bold;
             font-family: monospace; }
.readme pre { margin: 0; padding: 8px; background: #fff;
              border: 1px solid #ddd; overflow: auto;
              max-height: 400px;
              font: 13px/1.5 monospace; color: #000; }
hr { border: 0; border-top: 1px solid #ccc; margin: 18px 0 6px; }
address { font-style: normal; font-size: 11px; color: #777; }
.theme { float: right; font-size: 11px; color: #777; }
.theme a { color: #888; margin-left: 6px; }
.theme a.on { color: #000; font-weight: bold; text-decoration: none; }
\@media (prefers-color-scheme: dark) {
$dark_auto}
$dark_forced</style>
</head>
<body>
<h1>$esc_ttl</h1>
$readme_html<table>
<thead><tr><th></th><th>Name</th><th class="mtime">Last modified</th><th class="size">Size</th></tr></thead>
<tbody>
$row_html
</tbody>
</table>
<hr>
$toggle_html<address>$esc_footer</address>
</body>
</html>
HTML
}

sub _theme_toggle_html {
  my ($current) = @_;
  $current ||= 'auto';
  my @opts = (['auto', 'auto'], ['light', 'light'], ['dark', 'dark']);
  my @parts;
  for my $o (@opts) {
    my ($val, $label) = @$o;
    my $on = ($val eq $current) ? ' class="on"' : '';
    push @parts, qq{<a href="?set-theme=$val"$on>$label</a>};
  }
  return '<div class="theme">theme:' . join('', @parts) . '</div>';
}

# Dark palette emitted twice: once inside the prefers-color-scheme query
# (gated by :not(.t-light) so a forced-light cookie wins over the system),
# and once at top level keyed on html.t-dark (forced-dark cookie).
sub _dark_rules {
  my ($p) = @_;
  return <<"CSS";
$p body { background: #000; color: #b9c8d6; }
$p thead th { background: #0a1620; border-bottom-color: rgba(110,145,180,0.55); }
$p tbody td { border-bottom-color: rgba(110,145,180,0.18); }
$p tbody tr:hover { background: rgba(140,180,220,0.08); }
$p td.size, $p td.mtime { color: #8aa0b8; }
$p a { color: #6ea4d6; }
$p a:hover { color: #ffffff; }
$p .readme { background: #0a0e14; border-color: rgba(110,145,180,0.35); }
$p .readme pre { background: #000; color: #b9c8d6; border-color: rgba(110,145,180,0.35); }
$p hr { border-top-color: rgba(110,145,180,0.55); }
$p address, $p .theme { color: #6ea4d6; }
$p .theme a { color: #6ea4d6; }
$p .theme a.on { color: #ffffff; }
CSS
}

1;
