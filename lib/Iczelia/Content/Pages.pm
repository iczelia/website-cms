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

sub get_page {
  my ($self, $slug) = @_;
  return $self->{db}->row('SELECT * FROM pages WHERE slug=?', $slug);
}

sub save_page {
  my ($self, $slug, $title, $template, $data_json) = @_;
  $self->{db}->do_(
    q{
        UPDATE pages
           SET title=?, template=?, data=?, rendered_html=NULL,
               updated_at=strftime('%s','now')
         WHERE slug=?},
    $title, $template, $data_json, $slug
  );
  $self->{render}->invalidate_page($slug);
  $self->{render}->invalidate_home if $slug ne 'home';
}

1;
