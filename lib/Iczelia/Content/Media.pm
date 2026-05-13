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

# Iczelia::Content fragment. Full package layout in Content.pm.
# Provides: list_media, get_media, create_media, delete_media.
# Reads $self slots: db.

sub list_media {
  my ($self, $limit) = @_;
  $limit //= 200;
  return $self->{db}->all(
    q{SELECT id, filename, orig_name, content_type, size, sha256,
             uploaded_at, thumb_filename
        FROM media ORDER BY uploaded_at DESC LIMIT ?}, $limit
  );
}

sub get_media {
  my ($self, $id) = @_;
  return $self->{db}->row(
    'SELECT filename, thumb_filename FROM media WHERE id=?', $id
  );
}

sub create_media {
  my ($self, %m) = @_;
  $self->{db}->do_(
    q{INSERT OR IGNORE INTO media
        (filename, orig_name, content_type, size, sha256,
         uploaded_at, thumb_filename)
        VALUES(?, ?, ?, ?, ?, strftime('%s','now'), ?)},
    @m{qw(filename orig_name content_type size sha256 thumb_filename)}
  );
}

sub delete_media {
  my ($self, $id) = @_;
  $self->{db}->do_('DELETE FROM media WHERE id=?', $id);
}

1;
