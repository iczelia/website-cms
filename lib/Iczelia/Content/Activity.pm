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

sub list_activity {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT * FROM activity ORDER BY source, position'
  );
}

sub list_updates {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, date, body, position FROM updates
         ORDER BY date DESC, position DESC, id DESC'
  );
}

sub replace_updates {
  my ($self, $rows) = @_;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM updates');
      my $pos = scalar @$rows;
      for my $r (@$rows) {
        next unless ($r->{date} // '') =~ /^\d{4}-\d{2}-\d{2}$/;
        $d->do_('INSERT INTO updates(date, body, position) VALUES(?,?,?)',
          $r->{date}, ($r->{body} // ''), $pos--);
      }
    }
  );
  $self->{render}->invalidate_home;
  $self->{render}->invalidate_page('updates');
}

sub set_currently {
  my ($self, $text) = @_;
  $self->{db}->tx(
    sub {
      my $d = shift;
      $d->do_("DELETE FROM activity WHERE source='currently'");
      $d->do_(
        q{INSERT INTO activity(source, text, position, fetched_at)
                  VALUES('currently', ?, 0, strftime('%s','now'))}, $text
      ) if defined $text && length $text;
    }
  );
  $self->{render}->invalidate_home;
}

1;
