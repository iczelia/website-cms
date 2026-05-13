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

package Iczelia::Content;
use strict;
use warnings;

my %WEBRING_SECTIONS = map {$_ => 1} qw(own others more);

sub list_webring {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, position, section, name, url, image_url
         FROM webring_members ORDER BY position'
  );
}

sub replace_webring {
  my ($self, $rows) = @_;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM webring_members');
      my $pos = 0;
      for my $r (@$rows) {
        my $name    = $r->{name}      // '';
        my $url     = $r->{url}       // '';
        my $img     = $r->{image_url} // '';
        my $section = $r->{section}   // 'others';
        $section = 'others' unless $WEBRING_SECTIONS{$section};
        next      unless length $name;
        $url = '' unless $url =~ m{^https?://}i;
        next      unless length $url || length $img;
        $img = ''
          unless $img =~ m{^/(?:media|assets-)} || $img =~ m{^https?://}i;
        $d->do_(
          'INSERT INTO webring_members(position, section, name, url, image_url)
                 VALUES(?,?,?,?,?)',
          $pos++, $section, $name, $url,
          length $img ? $img : undef
        );
      }
    }
  );
  $self->{render}->invalidate_page('webring');
}

1;
