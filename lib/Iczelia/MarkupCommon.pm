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

package Iczelia::MarkupCommon;
use strict;
use warnings;
use Exporter qw(import);

# Helpers shared by Iczelia::Markup (admin-trusted) and
# Iczelia::SafeMarkup (untrusted). Keeping the math extraction and
# code-span dollar-hide in one place stops fixes from drifting between
# the two parsers.

our @EXPORT_OK = qw(
  hide_code_dollars
  restore_code_dollars
  extract_math
);

# Cap a single math fragment's source. Tex.pm rejects past 16 KB.
use constant MAX_MATH_SRC => 32 * 1024;

sub _hide_dollars {my $s = shift; $s =~ tr/$/\x{E600}/; $s}

# Replaces $ with a PUA sentinel inside fenced and inline code spans
# so the math extractor below leaves them alone. Inline code spans are
# line-restricted to prevent a stray ` in one fenced block from pairing
# with another stray ` later and swallowing math in the prose between.
sub hide_code_dollars {
  my ($src) = @_;
  $src =~ s{(^```[^\n]*\n)(.*?)(\n```[ \t]*(?=\n|\z))}{
        $1 . _hide_dollars($2) . $3
    }gmse;
  $src =~ s{(?<!`)(`+)(?!`)((?:[^`\n]|`(?!\1))+?)(\1)(?!`)}{
        $1 . _hide_dollars($2) . $3
    }ge;
  return $src;
}

sub restore_code_dollars {
  my ($src) = @_;
  $src =~ tr/\x{E600}/\$/;
  return $src;
}

# Pulls $$display$$ first, then $inline$ math out of $src into @$math
# (each entry [display_flag, tex_source]), replacing the source with
# \x{E000}N\x{E001} placeholders. Pandoc rule: closing $ followed by
# a digit is text, not math.
sub extract_math {
  my ($src, $math) = @_;
  my $cap = MAX_MATH_SRC;
  $src =~ s{ \$\$ ( (?:[^\$\\]|\\.){0,$cap}? ) \$\$ }{
        push @$math, [ 1, $1 ];
        sprintf "\x{E000}%d\x{E001}", $#$math;
    }gxe;
  $src =~ s{ (?<![\\\$]) \$ ( (?:[^\$\n\\]|\\.){1,$cap}? ) \$ (?!\d) }{
        push @$math, [ 0, $1 ];
        sprintf "\x{E000}%d\x{E001}", $#$math;
    }gxe;
  return $src;
}

1;
