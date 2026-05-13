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

package Iczelia::Render;
use strict;
use warnings;
use Iczelia::Minify ();

# Iczelia::Render fragment. Full package layout in Render.pm.
# Provides: _home_css.
# Reads $self slots: cfg, _home_css (memoized here).
# Calls cross-file helpers: none.

sub _home_css {
  my ($self) = @_;
  return $self->{_home_css} ||= do {
    my $dir = $self->{cfg} && $self->{cfg}{'chrome-dir'};
    my %out;
    if ($dir) {
      my %map = (
        common => 'common.compat.css',
        s600   => 'style.600.compat.css',
        mobile => 'style.mobile.compat.css',
        s800   => 'style.800.compat.css',
        s1024  => 'style.1024.compat.css',
      );
      for my $k (keys %map) {
        my $path = "$dir/$map{$k}";
        open my $fh, '<:encoding(UTF-8)', $path
          or do {$out{$k} = ''; next};
        local $/;
        my $css = <$fh>;
        close $fh;
        $out{$k} = Iczelia::Minify::css($css);
      }
    }
    \%out;
  };
}

1;
