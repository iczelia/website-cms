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

package Iczelia::PublicListing;
use strict;
use warnings;
use Iczelia           ();
use Iczelia::Util     qw(escape_html);
use Iczelia::Theme    ();

# Apache-style listing chrome shared by the subpage directory index and
# the git tree view. CSS is plain (no custom properties, no flexbox) so
# the IE9 / FF3.5 / Chrome 4 floor still renders the light theme intact;
# the dark palette lives behind @media (prefers-color-scheme: dark) and a
# .t-dark class for users who picked dark explicitly.

sub footer_for {
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

# render_listing(%args)
#   title         => 'Index of /foo/'
#   rows          => arrayref of {
#                      icon         => 'folder.png' | extension icon
#                      name_href    => '<a href="...">name</a>' (already HTML)
#                      mtime        => '2026-01-01 00:00' or '-'
#                      size         => '1.2 KB' or '-'
#                      extra_cells  => optional [$cell_html, ...]
#                    }
#   readme        => optional { name => $, content => $ } (plain text README)
#   footer        => plain-text footer string
#   theme         => 'auto' | 'light' | 'dark'
#   extra_columns => optional [$th_label, ...] aligned with row->extra_cells
sub render_listing {
  my %a = @_;
  my $title         = defined $a{title} ? $a{title} : '';
  my $rows          = $a{rows} || [];
  my $readme        = $a{readme};
  my $footer        = $a{footer};
  my $theme         = $a{theme} // 'auto';
  my $extra_columns = $a{extra_columns} || [];

  my $esc_ttl    = escape_html($title);
  my $html_class = Iczelia::Theme::html_class($theme);

  my $extra_th = '';
  for my $lbl (@$extra_columns) {
    $extra_th .= '<th class="commit">' . escape_html($lbl) . '</th>';
  }

  my @rendered;
  for my $r (@$rows) {
    my $icon  = defined $r->{icon}  ? $r->{icon}  : 'file.png';
    my $name  = defined $r->{name_href} ? $r->{name_href} : '';
    my $mtime = defined $r->{mtime} ? $r->{mtime} : '-';
    my $size  = defined $r->{size}  ? $r->{size}  : '-';
    my $extra = '';
    if ($r->{extra_cells}) {
      for my $cell (@{$r->{extra_cells}}) {
        $extra .= '<td class="commit">' . (defined $cell ? $cell : '') . '</td>';
      }
    }
    push @rendered,
        qq{<tr><td class="icon"><img src="/cms-icons/$icon" alt=""></td>}
      . qq{<td class="name">$name</td>}
      . qq{<td class="mtime">$mtime</td>}
      . qq{<td class="size">$size</td>$extra</tr>};
  }
  my $row_html = join "\n", @rendered;

  my $readme_html = '';
  if ($readme && defined $readme->{content}) {
    my $name = escape_html($readme->{name} // 'README');
    my $body = escape_html($readme->{content});
    $readme_html =
        qq{<section class="readme"><h2>$name</h2>}
      . qq{<pre><code>$body</code></pre></section>\n};
  }

  my $esc_footer  = escape_html(defined $footer ? $footer : '');
  my $toggle_html = Iczelia::Theme::toggle_html($theme);
  my $dark_auto   = Iczelia::Theme::dark_rules('  html:not(.t-light)');
  my $dark_forced = Iczelia::Theme::dark_rules('html.t-dark');

  return <<"HTML";
<!DOCTYPE html>
<html lang="en"$html_class>
<head>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
<meta name="color-scheme" content="light dark">
<title>$esc_ttl</title>
<style>
body { font-family: Arial, sans-serif; color: #000; background: #fff;
       margin: 16px 24px; max-width: 1024px; }
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
td.commit { font-size: 12px; color: #555; }
thead th.size, thead th.mtime { text-align: right; }
a { color: #1a3a7a; text-decoration: none; }
a:hover { color: #4a6da7; text-decoration: underline; }
.readme { display: block; background: #fafafa; border: 1px solid #ccc;
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
<thead><tr><th></th><th>Name</th><th class="mtime">Last modified</th><th class="size">Size</th>$extra_th</tr></thead>
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

1;
