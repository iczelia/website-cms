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

package Iczelia::Slop::Tokenizer;
use strict;
use warnings;
use Encode ();
use Carp   qw(croak);

# Pure-Perl SentencePiece BPE tokenizer for arnir0/Tiny-LLM.
#
# Encode: prepend U+2581, substitute spaces with U+2581, then
# greedily apply BPE merges by priority. Characters that aren't in the
# vocab fall back to the byte-level <0x..> tokens at ids 3..258.
#
# Decode: map ids back to pieces, accumulate consecutive byte-fallback
# tokens into a UTF-8 buffer, then flush; replace U+2581 with space.

my $SPC = "\x{2581}";

sub new {
  my ($class, %arg) = @_;
  my $tk = $arg{tokenizer} or croak "tokenizer hash required";
  my $vocab = $tk->{vocab};

  # Pair rank table: "$a\t$b" => priority. Lower means apply earlier.
  my %rank;
  my $merges = $tk->{merges} || [];
  for (my $i = 0; $i < @$merges; $i++) {
    my $m = $merges->[$i];
    next unless ref($m) eq 'ARRAY' && @$m >= 2;
    $rank{"$m->[0]\t$m->[1]"} = $i;
  }

  # Precompute the byte-fallback piece ids so we don't hash-lookup
  # "<0x__>" strings during encoding.
  my @byte_ids;
  for my $b (0 .. 255) {
    my $key = sprintf '<0x%02X>', $b;
    my $id  = $vocab->{$key};
    $byte_ids[$b] = defined $id ? $id : ($tk->{unk_id} // 0);
  }

  my %is_special = map {$_ => 1} @{$tk->{special_ids} || []};

  return bless {
    vocab       => $vocab,
    id_to_piece => $tk->{id_to_piece},
    rank        => \%rank,
    byte_ids    => \@byte_ids,
    bos_id      => $tk->{bos_id}      // 1,
    eos_id      => $tk->{eos_id}      // 2,
    unk_id      => $tk->{unk_id}      // 0,
    is_special  => \%is_special,
  }, $class;
}

sub bos_id {$_[0]{bos_id}}
sub eos_id {$_[0]{eos_id}}

sub encode {
  my ($self, $text, %opt) = @_;
  my $add_bos = exists $opt{bos} ? $opt{bos} : 1;

  $text = Encode::decode('UTF-8', $text)
    unless Encode::is_utf8($text);

  # LlamaTokenizer with add_prefix_space=True.
  $text =~ s/ /$SPC/g;
  $text = $SPC . $text;

  my @pieces = split //, $text;
  return [$add_bos ? ($self->{bos_id}) : ()] unless @pieces;

  my $rank   = $self->{rank};
  my $vocab  = $self->{vocab};

  # Greedy BPE: each pass scans for the pair with the lowest rank and
  # merges it. Repeat until no scoring pair remains. n^2 per pass, n
  # passes worst case — acceptable for the ~30-byte prompts we feed.
  while (1) {
    my $best_idx = -1;
    my $best_rank;
    for (my $i = 0; $i < $#pieces; $i++) {
      my $r = $rank->{"$pieces[$i]\t$pieces[$i+1]"};
      next unless defined $r;
      if (!defined $best_rank || $r < $best_rank) {
        $best_rank = $r;
        $best_idx  = $i;
      }
    }
    last if $best_idx < 0;
    splice @pieces, $best_idx, 2, $pieces[$best_idx] . $pieces[$best_idx + 1];
  }

  my @ids;
  push @ids, $self->{bos_id} if $add_bos;
  my $byte_ids = $self->{byte_ids};
  for my $p (@pieces) {
    if (defined(my $id = $vocab->{$p})) {
      push @ids, $id;
      next;
    }

    # Byte fallback: emit one <0x..> token per UTF-8 byte.
    my $bytes = Encode::encode('UTF-8', $p);
    push @ids, $byte_ids->[$_] for unpack 'C*', $bytes;
  }
  return \@ids;
}

sub decode {
  my ($self, $ids, %opt) = @_;
  my $skip_special = exists $opt{skip_special} ? $opt{skip_special} : 1;
  my $is_special   = $self->{is_special};
  my $pieces       = $self->{id_to_piece};

  my $out   = '';
  my $bytes = '';
  for my $id (@$ids) {
    next if $skip_special && $is_special->{$id};
    my $p = $pieces->[$id];
    next unless defined $p;
    if (length($p) == 6 && substr($p, 0, 3) eq '<0x' && substr($p, -1) eq '>') {
      $bytes .= chr(hex(substr($p, 3, 2)));
      next;
    }
    if (length $bytes) {
      $out .= Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT());
      $bytes = '';
    }
    $out .= $p;
  }
  $out .= Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT())
    if length $bytes;

  $out =~ s/$SPC/ /g;
  $out =~ s/^ +//;
  return $out;
}

# Decode a single token id incrementally. Returns ('text', $string)
# for a printable piece, or ('byte', $chr) for a byte-fallback piece
# that the caller should buffer until a non-byte arrives. Special
# tokens return ('skip').
sub decode_one {
  my ($self, $id) = @_;
  return ('skip') if $self->{is_special}{$id};
  my $p = $self->{id_to_piece}[$id];
  return ('skip') unless defined $p;
  if (length($p) == 6 && substr($p, 0, 3) eq '<0x' && substr($p, -1) eq '>') {
    return ('byte', chr(hex(substr($p, 3, 2))));
  }
  $p =~ s/$SPC/ /g;
  return ('text', $p);
}

1;
