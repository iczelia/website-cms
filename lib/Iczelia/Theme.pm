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

package Iczelia::Theme;
use strict;
use warnings;
use Iczelia::HTTP ();

# Theme persistence without JavaScript, shared between the subpage
# directory index and the git browser:
#   * cookie `iczelia_theme` (light|dark, missing = auto/system)
#   * `?set-theme=light|dark|auto` writes the cookie and 303-redirects
#     back to the clean URL so the next render picks up the new value.

use constant COOKIE => 'iczelia_theme';

sub from_cookie {
  my ($req) = @_;
  my $v = $req && $req->{cookies} && $req->{cookies}{+COOKIE};
  return $v && ($v eq 'light' || $v eq 'dark') ? $v : 'auto';
}

sub wanted_from_query {
  my ($req) = @_;
  my $v = $req && $req->{qparams} && $req->{qparams}{'set-theme'};
  return undef unless defined $v;
  return undef unless $v eq 'light' || $v eq 'dark' || $v eq 'auto';
  return $v;
}

sub apply_response {
  my ($req, $value) = @_;
  my %c = (name => COOKIE, path => '/', samesite => 'Lax');
  if ($value eq 'auto') { $c{value} = ''; $c{max_age} = 0 }
  else                  { $c{value} = $value; $c{max_age} = 60 * 60 * 24 * 365 }
  $c{secure} = 1 if Iczelia::HTTP::is_https($req);
  my $resp = Iczelia::HTTP::redirect($req->{path}, status => 303);
  $resp->{cookies}   = [Iczelia::HTTP::make_cookie(%c)];
  $resp->{_no_cache} = 1;
  return $resp;
}

sub html_class {
  my ($current) = @_;
  return ' class="t-light"' if defined $current && $current eq 'light';
  return ' class="t-dark"'  if defined $current && $current eq 'dark';
  return '';
}

sub toggle_html {
  my ($current) = @_;
  $current ||= 'auto';
  my @parts;
  for my $val (qw(auto light dark)) {
    my $on = $val eq $current ? ' class="on"' : '';
    push @parts, qq{<a href="?set-theme=$val"$on>$val</a>};
  }
  return '<div class="theme">theme:' . join('', @parts) . '</div>';
}

# Dark palette as CSS rules, prefixed with $p so the same body can be
# emitted twice: inside the prefers-color-scheme @media (with
# :not(.t-light) so a forced-light cookie wins over system dark), and
# once at top level keyed on html.t-dark (forced-dark cookie).
sub dark_rules {
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
