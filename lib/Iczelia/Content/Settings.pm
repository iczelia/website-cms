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
# Provides: all_settings, set_settings.
# Reads $self slots: db, render.

sub all_settings {
  my ($self) = @_;
  my $rows = $self->{db}->all('SELECT key, value FROM settings ORDER BY key');
  my %h;
  $h{$_->{key}} = $_->{value} for @$rows;
  return \%h;
}

sub set_settings {
  my ($self, $kv) = @_;
  my $math_changed = grep {/^math\./} keys %$kv;

  $self->{db}->tx(
    sub {
      my $d = shift;
      for my $k (keys %$kv) {
        $d->do_(
          q{INSERT INTO settings(key, value) VALUES(?,?)
                      ON CONFLICT(key) DO UPDATE SET value=excluded.value},
          $k, $kv->{$k} // ''
        );
      }
    }
  );

  # Settings touch every page; wipe response_cache and per-row
  # rendered_html. The tex_cache DELETE is hygiene (the key already
  # encodes math params).
  $self->{render}->invalidate_all;
  $self->{db}->do_('UPDATE pages SET rendered_html = NULL');
  $self->{db}->do_('UPDATE posts SET rendered_html = NULL');
  if ($math_changed) {
    $self->{db}->do_('DELETE FROM tex_cache');
  }
}

1;
