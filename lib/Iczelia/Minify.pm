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

package Iczelia::Minify;
use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(css html);

# Minify CSS / HTML for the response cache. Run once on cold cache (right
# before brotli + gzip) so live requests serve the byte-tightest possible
# representation. The savings on raw bytes are modest but they stack
# multiplicatively with compression: minified+brotli is typically 25-35%
# smaller than raw+brotli.

sub css {
  my ($s) = @_;
  return $s unless defined $s && length $s;

  # /* ... */ comments. Non-greedy across newlines.
  $s =~ s{/\*.*?\*/}{}gs;

  # Collapse whitespace runs to a single space.
  $s =~ s/[ \t\r\n\f]+/ /g;

  # Drop space immediately around structural punctuation.
  $s =~ s/\s*([{};:,>+~()])\s*/$1/g;

  # Drop the last semicolon before a closing brace.
  $s =~ s/;}/}/g;

  # Trim leading/trailing.
  $s =~ s/^\s+//;
  $s =~ s/\s+$//;
  return $s;
}

# Tags whose contents must stay byte-for-byte intact.
my $VERBATIM_RE = qr{<(pre|textarea|script|style)\b[^>]*>.*?</\1>}is;

# Block-level tags. Whitespace immediately around their opening / closing
# form is strippable since browsers treat any amount of inter-block
# whitespace identically (it's not part of the rendered text flow).
my $BLOCK_TAGS = join '|', qw(
  html head body
  div p ul ol li dl dt dd
  h1 h2 h3 h4 h5 h6
  section article nav header footer main aside
  table tr td th tbody thead tfoot caption colgroup col
  blockquote figure figcaption hr br
  form fieldset legend
  address details summary menu hgroup
  link meta title style script
);
my $BLOCK_RE = qr{</?(?:$BLOCK_TAGS)\b};

sub html {
  my ($s) = @_;
  return $s unless defined $s && length $s;

  # Walk the string, splitting off verbatim regions so we never touch
  # the bytes inside <pre> / <textarea> / <script> / <style>.
  my $out = '';
  my $pos = 0;
  while ($s =~ /$VERBATIM_RE/g) {
    my $start = $-[0];
    my $end   = $+[0];
    $out .= _collapse(substr($s, $pos, $start - $pos));
    $out .= substr($s, $start, $end - $start);
    $pos = $end;
  }
  $out .= _collapse(substr($s, $pos));
  return $out;
}

sub _collapse {
  my ($s) = @_;
  return $s unless length $s;

  # Drop comments - keep IE conditional comments intact (`<!--[if ...]>`
  # and matching `<![endif]-->`) on the off chance future markup uses them.
  $s =~ s{<!--(?!\[if|<!\[endif).*?-->}{}gs;

  # Collapse runs of whitespace to a single space.
  $s =~ s/[ \t\r\n\f]+/ /g;

  # Drop whitespace adjacent to block-level tags. Inter-block whitespace
  # never affects rendering, while inter-inline whitespace (which we
  # leave alone) does.
  $s =~ s/\s+(?=$BLOCK_RE)//g;
  $s =~ s/($BLOCK_RE[^>]*>)\s+/$1/g;
  return $s;
}

1;
