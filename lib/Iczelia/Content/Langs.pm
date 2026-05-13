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
use Iczelia::Highlight ();

sub list_langs {
  my ($self) = @_;
  return $self->{db}->all(
    'SELECT id, name, aliases, updated_at, version
           FROM highlight_langs ORDER BY name'
  );
}

sub get_lang {
  my ($self, $id) = @_;
  return $self->{db}->row('SELECT * FROM highlight_langs WHERE id=?', $id);
}

sub _validate_lang_name {
  my ($n) = @_;
  return 0 unless defined $n && length $n;
  return $n =~ /^[a-z][a-z0-9+_:-]{0,40}$/ ? 1 : 0;
}

sub _validate_lang_record {
  my ($self, $rec, $cur_id) = @_;
  my $name = lc($rec->{name} // '');
  return (undef, 'name required') unless length $name;
  return (undef, 'name must be lowercase letters/digits/-_+:')
    unless _validate_lang_name($name);

  # Reject collisions against built-ins or other admin-defined langs.
  if (Iczelia::Highlight::known($name)) {
    my $row =
      $self->{db}->row('SELECT id FROM highlight_langs WHERE name=?', $name);
    if (!$row || ($cur_id && $row->{id} != $cur_id)) {
      return (undef, "name '$name' is reserved or in use");
    }
  }
  my @aliases;
  for my $a (split /[\s,]+/, ($rec->{aliases} // '')) {
    my $la = lc $a;
    next unless length $la;
    return (undef, "alias '$a' invalid")
      unless _validate_lang_name($la);
    next if $la eq $name;
    push @aliases, $la;
  }

  # Token strings are stored verbatim; Highlight::_build_db_rules
  # drops anything not matching [\w][\w:-]{0,63}, so junk is safe.
  my $lcm = $rec->{line_comment} // '';
  if (length $lcm
    && !($lcm =~ /^[[:punct:]]{1,3}$/ && $lcm =~ /^[\x21-\x7e]+$/))
  {
    return (undef, 'line_comment must be 1-3 ASCII punctuation chars');
  }
  my $bcm = $rec->{block_comment} // '';
  if (length $bcm && $bcm !~ /^\s*\S{1,3}\s+\S{1,3}\s*$/) {
    return (undef, 'block_comment must be "OPEN CLOSE"');
  }
  my $sq = $rec->{string_quotes} // '"';
  return (undef, 'string_quotes must be 1-4 chars')
    if length $sq < 1 || length $sq > 4;
  return (
    {
      name          => $name,
      aliases       => join(',', @aliases),
      keywords      => $rec->{keywords} // '',
      types         => $rec->{types}    // '',
      builtins      => $rec->{builtins} // '',
      line_comment  => $lcm,
      block_comment => $bcm,
      string_quotes => $sq,
    },
    undef
  );
}

sub create_lang {
  my ($self,  $rec) = @_;
  my ($clean, $err) = $self->_validate_lang_record($rec, undef);
  return (undef, $err) if $err;
  eval {
    $self->{db}->do_(
      q{
            INSERT INTO highlight_langs(
                name, aliases, keywords, types, builtins,
                line_comment, block_comment, string_quotes,
                updated_at, version)
            VALUES(?,?,?,?,?,?,?,?, strftime('%s','now'), 1)},
      $clean->{name},         $clean->{aliases}, $clean->{keywords},
      $clean->{types},        $clean->{builtins},
      $clean->{line_comment}, $clean->{block_comment},
      $clean->{string_quotes}
    );
    1;
  } or do {
    my $e = $@;
    return (undef, "insert failed: $e");
  };
  my $id = $self->{db}->last_id;
  $self->{render}->invalidate_all if $self->{render};
  return ($id, undef);
}

sub update_lang {
  my ($self, $id, $rec) = @_;
  my $cur = $self->get_lang($id) or return (undef, 'not found');
  my ($clean, $err) = $self->_validate_lang_record($rec, $id);
  return (undef, $err) if $err;
  $self->{db}->do_(
    q{
        UPDATE highlight_langs
           SET name=?, aliases=?, keywords=?, types=?, builtins=?,
               line_comment=?, block_comment=?, string_quotes=?,
               updated_at=strftime('%s','now'),
               version=version+1
         WHERE id=?},
    $clean->{name},          $clean->{aliases}, $clean->{keywords},
    $clean->{types},         $clean->{builtins},
    $clean->{line_comment},  $clean->{block_comment},
    $clean->{string_quotes}, $id
  );
  $self->{render}->invalidate_all if $self->{render};
  return ($id, undef);
}

sub delete_lang {
  my ($self, $id) = @_;
  $self->{db}->do_('DELETE FROM highlight_langs WHERE id=?', $id);
  $self->{render}->invalidate_all if $self->{render};
}

1;
