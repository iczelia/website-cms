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

package Iczelia::OG;
use strict;
use warnings;
use Encode           ();
use Iczelia::Process ();
use Iczelia::Util    qw(escape_html);

# Auto-generated Open Graph cards. generate($title, %opt) returns PNG
# bytes (1200x630), built by composing an SVG and piping it through
# ImageMagick `convert`. The SVG is the source of truth; ImageMagick
# is only the rasteriser.
#
# Options:
#   author       site author (right-side footer).
#   site         site title (footer prefix).
#   kappa        Greek-letter classifier glyph, drawn faint in the
#                background as a watermark. Optional.
#   subtitle     small caption above the title (e.g., post date).
#
# Returns undef when ImageMagick is missing or rasterisation fails;
# callers are expected to handle the absent-card case (no og:image
# stamping, no cache write).

use constant {
  CARD_W    => 1200,
  CARD_H    => 630,
  BG        => '#0a0e18',
  FG        => '#ffffff',
  DIM       => '#7a8aa8',
  ACCENT    => '#5fb3d0',
  KAPPA_DIM => '#1a2538',
};

sub generate {
  my ($title, %opt) = @_;
  return undef unless defined $title && length $title;

  my $svg = _build_svg($title, %opt);
  return undef unless defined $svg;

  return _svg_to_png($svg);
}

# Wrap a title to at most $max_lines lines fitting roughly $max_cols
# columns each. Greedy by character count; not pixel-aware but enough
# for typical post titles.
sub _wrap_title {
  my ($title, $max_cols, $max_lines) = @_;
  $max_cols  ||= 28;
  $max_lines ||= 4;
  my @words = split /\s+/, $title;
  my @lines;
  my $cur = '';
  for my $w (@words) {
    if (!length $cur) {$cur = $w; next}
    if (length($cur) + 1 + length($w) <= $max_cols) {
      $cur .= ' ' . $w;
    }
    else {
      push @lines, $cur;
      $cur = $w;
      last if @lines >= $max_lines;
    }
  }
  push @lines, $cur if length $cur && @lines < $max_lines;
  if (@lines == $max_lines && @words) {

    # Crude truncation when the title overflows the box.
    $lines[-1] =~ s/\s*\S*\s*$/.../ if length $lines[-1] > $max_cols - 3;
  }
  return @lines;
}

sub _build_svg {
  my ($title, %opt) = @_;
  my $author   = $opt{author}   // '';
  my $site     = $opt{site}     // '';
  my $kappa    = $opt{kappa}    // '';
  my $subtitle = $opt{subtitle} // '';

  my @lines  = _wrap_title($title, 26, 4);
  return undef unless @lines;

  # Centre the title block vertically: ~88px per line baseline.
  my $line_h     = 88;
  my $title_top  = int((CARD_H - @lines * $line_h) / 2) + 70;
  my $bg         = BG;
  my $fg         = FG;
  my $dim        = DIM;
  my $accent     = ACCENT;
  my $kappa_dim  = KAPPA_DIM;
  my $w          = CARD_W;
  my $h          = CARD_H;

  my @bits;
  push @bits,
    qq{<?xml version="1.0" encoding="UTF-8"?>\n},
    qq{<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h" font-family="Helvetica, Arial, sans-serif">\n};
  push @bits, qq{<rect width="$w" height="$h" fill="$bg"/>\n};

  # Faint kappa watermark in the bottom-right when present.
  if (length $kappa) {
    my $g_x = $w - 80;
    my $g_y = $h - 60;
    my $gly = escape_html($kappa);
    push @bits,
      qq{<text x="$g_x" y="$g_y" font-size="380" fill="$kappa_dim" font-weight="700" text-anchor="end" opacity="0.55">$gly</text>\n};
  }

  # Top accent bar.
  push @bits,
    qq{<rect x="60" y="58" width="160" height="6" fill="$accent"/>\n};

  if (length $subtitle) {
    my $st = escape_html($subtitle);
    push @bits,
      qq{<text x="60" y="120" font-size="28" fill="$dim" letter-spacing="2">$st</text>\n};
  }

  # Title lines.
  for my $i (0 .. $#lines) {
    my $y    = $title_top + $i * $line_h;
    my $text = escape_html($lines[$i]);
    push @bits,
      qq{<text x="60" y="$y" font-size="72" fill="$fg" font-weight="700">$text</text>\n};
  }

  # Footer: site / author on the bottom.
  my $foot_y = $h - 60;
  my $footer = join ' / ', grep {length} ($site, $author);
  $footer = escape_html($footer);
  if (length $footer) {
    push @bits,
      qq{<text x="60" y="$foot_y" font-size="28" fill="$dim">$footer</text>\n};
  }

  push @bits, qq{</svg>\n};
  return join '', @bits;
}

sub _svg_to_png {
  my ($svg) = @_;
  return undef unless Iczelia::Process::have_bin('convert');
  my $bytes = Encode::is_utf8($svg) ? Encode::encode_utf8($svg) : $svg;

  # `-` stdin -> `-` stdout. -density 96 keeps font metrics consistent
  # with the SVG viewBox; -background keeps SVG opacity from showing
  # through as black on render.
  my $png = Iczelia::Process::run_capped(
    ['convert', '-background', 'none', '-density', '96',
      'svg:-', 'png:-'],
    body    => $bytes,
    timeout => 8,
  );
  return undef unless defined $png && length $png > 100;
  return $png;
}

1;
