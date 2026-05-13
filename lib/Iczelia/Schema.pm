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

package Iczelia::Schema;
use strict;
use warnings;
use Carp          qw(croak);
use JSON::PP      ();
use File::Spec    ();
use Iczelia::Util ();

# Per-template page schemas (share/templates/pages/<tpl>.json) and
# admin-form -> typed-record parsing. parse_form -> (\%data, \%errs).

my $JSON = JSON::PP->new->utf8(0);

sub new {
  my ($class, %arg) = @_;
  croak "dir required" unless $arg{dir};
  return bless {dir => $arg{dir}, cache => {}}, $class;
}

sub load {
  my ($self, $name) = @_;
  return $self->{cache}{$name} if $self->{cache}{$name};
  my $path = File::Spec->catfile($self->{dir}, "$name.json");
  open my $fh, '<:raw', $path or croak "schema $name not found at $path";
  local $/;
  my $src = <$fh>;
  close $fh;
  my $sch = $JSON->decode($src);
  return $self->{cache}{$name} = $sch;
}

# Parse form parameters according to a schema. Returns ($data, $errors).
sub parse_form {
  my ($self, $name, $params) = @_;
  my $sch = $self->load($name);
  my %data;
  my %errs;
  for my $f (@{$sch->{fields}}) {
    my ($v, $e) = _parse_field($f, $params);
    $data{$f->{name}} = $v;
    $errs{$f->{name}} = $e if defined $e;
  }
  return (\%data, \%errs);
}

sub _parse_field {
  my ($f, $params) = @_;
  my $name = $f->{name};
  my $kind = $f->{kind};

  if ($kind eq 'markdown' || $kind eq 'markdown_inline' || $kind eq 'text') {
    my $v = $params->{$name};
    $v = '' unless defined $v;
    $v =~ s/\r\n/\n/g;
    if (defined $f->{max} && length($v) > $f->{max}) {
      return ($v, "max length $f->{max}");
    }
    return ($v, undef);
  }

  if ($kind eq 'int') {
    my $v = $params->{$name};
    if (!defined $v || $v eq '') {
      return ($f->{default} // 0, undef);
    }
    unless ($v =~ /^-?\d+$/) {
      return ($f->{default} // 0, 'not an integer');
    }
    $v += 0;
    if (defined $f->{min} && $v < $f->{min}) {
      return ($f->{min}, "min $f->{min}");
    }
    if (defined $f->{max} && $v > $f->{max}) {
      return ($f->{max}, "max $f->{max}");
    }
    return ($v, undef);
  }

  if ($kind eq 'bool') {
    my $v = $params->{$name};
    return ((defined $v && ($v eq '1' || $v eq 'on' || $v eq 'true')) ? 1 : 0,
      undef);
  }

  if ($kind eq 'kv-table') {

    # `${name}__json` blob preferred; otherwise per-cell fields.
    my $rows = [];
    if (defined $params->{"$name\__json"}) {
      my $arr = eval {$JSON->decode($params->{"$name\__json"})};
      $rows = $arr if ref $arr eq 'ARRAY';
    }
    else {
      # Cap accepted row indices so a hostile form post can't
      # inflate %by_row with `__row99999999__x` keys.
      my %by_row;
      for my $k (keys %$params) {
        if ($k =~ /^\Q$name\E__row(\d{1,4})__([\w-]+)$/) {
          next if $1 + 0 > 999;
          $by_row{$1}{$2} = $params->{$k};
        }
      }
      for my $idx (sort {$a <=> $b} keys %by_row) {
        my $r   = $by_row{$idx};
        my $any = grep {defined $_ && length $_} values %$r;
        next unless $any;
        push @$rows, $r;
      }
    }
    return ($rows, undef);
  }

  return ($params->{$name}, undef);
}

sub encode {
  my ($self, $data) = @_;
  return JSON::PP->new->canonical(1)->utf8(0)->encode($data);
}

sub decode {
  my ($self, $s) = @_;
  return Iczelia::Util::decode_json_hash($s);
}

1;
