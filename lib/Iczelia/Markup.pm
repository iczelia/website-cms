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

package Iczelia::Markup;
use strict;
use warnings;
use Iczelia::Util      qw(escape_html);
use Iczelia::Highlight ();
use Iczelia::MarkupCommon
  qw(hide_code_dollars restore_code_dollars extract_math);

# CommonMark-ish, with angle brackets escaped (no HTML passthrough).
# Math becomes __MATH<n>__ placeholders for Iczelia::Render to fill.

use constant MAX_NEST => 8;    # blockquote / list nesting cap

# Per-render state, dynamic-scoped via local() at the top of render():
# refs, fnotes, fn_seq, fn_idx.
our $STATE;

# render($src) -> ($html, \@math) where @math is [display, latex] pairs
# in placeholder order.
sub render {
  my ($src, $depth) = @_;
  $depth ||= 0;
  return ('', []) unless defined $src && length $src;
  if ($depth > MAX_NEST) {
    return (escape_html($src), []);
  }

  my @math;
  my @raw_html;
  my $is_top = ($depth == 0);
  my %local_state;
  local $STATE = $STATE;

  if ($is_top) {

    # RAWHTML segments are admin-trusted passthrough; SafeMarkup
    # never sees them.
    $src =~ s{<!--RAWHTML-->(.*?)<!--/RAWHTML-->}{
            push @raw_html, $1;
            sprintf "\x{E400}%d\x{E401}", $#raw_html;
        }gse;

    $src = hide_code_dollars($src);
    $src = extract_math($src, \@math);
    $src = restore_code_dollars($src);

    # Strip reference-link and footnote definitions into $STATE.
    my $refs   = _extract_link_refs(\$src);
    my $fnotes = _extract_footnotes(\$src);
    %local_state = (
      refs   => $refs,
      fnotes => $fnotes,
      fn_seq => [],        # populated as inline footnote refs are seen
      fn_idx => {},        # id -> 1-based number
    );
    $STATE = \%local_state;
  }

  my @lines = split /\n/, $src, -1;
  my @blocks;
  my $i = 0;

  while ($i < @lines) {
    my $line = $lines[$i];

    if ($line =~ /^\s*$/) {$i++; next}

    if ($line =~ /^```\s*(\S*)\s*$/) {
      my $lang = $1;
      my @body;
      $i++;
      while ($i < @lines && $lines[$i] !~ /^```\s*$/) {
        push @body, $lines[$i++];
      }
      $i++ if $i < @lines;
      my $code = join("\n", @body);
      push @blocks, Iczelia::Highlight::highlight($code, $lang);
      next;
    }

    if ($line =~ /^(#{1,6})\s+(.+?)\s*#*\s*$/) {
      push @blocks, _atx_heading(length $1, $2);
      $i++;
      next;
    }

    # Below the paragraph collector's setext check, so we only
    # fire when no preceding paragraph could promote.
    if ($line =~ /^[-*_]{3,}\s*$/) {
      push @blocks, "<hr>";
      $i++;
      next;
    }

    if ($line =~ /^>\s?(.*)$/) {
      my @body;
      while ($i < @lines && $lines[$i] =~ /^>\s?(.*)$/) {
        push @body, $1;
        $i++;
      }
      my ($inner) = render(join("\n", @body), $depth + 1);
      push @blocks, "<blockquote>$inner</blockquote>";
      next;
    }

    # GFM table; leading/trailing pipe optional.
    if ( $line =~ /\|/
      && ($i + 1) < @lines
      && $lines[$i + 1] =~ _table_sep_re())
    {
      my @rows;
      while ($i < @lines && $lines[$i] =~ /\|/) {
        push @rows, $lines[$i++];
      }
      push @blocks, _table(\@rows);
      next;
    }

    if ($line =~ /^(\s*)([-*+]|\d+\.)\s+(.*)$/) {
      my $is_ol = $2 =~ /\d/;
      my @items;
      my $base_indent = length($1 // '');
      while ($i < @lines && $lines[$i] =~ /^(\s*)([-*+]|\d+\.)\s+(.+)$/) {
        my $cur_indent = length($1 // '');
        last if $cur_indent < $base_indent;
        push @items, [$cur_indent, $3];
        $i++;
        while ($i < @lines && $lines[$i] =~ /^\s{4,}(.+)$/) {
          $items[-1][1] .= "\n" . $1;
          $i++;
        }
      }
      push @blocks, _list(\@items, $is_ol);
      next;
    }

    # Definition list: DT then DDs, terminated by blank or non-`:`.
    if ( $i + 1 < @lines
      && $lines[$i + 1] =~ /^:\s+/
      && $line !~ /^:\s+/)
    {
      my $term = $line;
      $i++;
      my @defs;
      while ($i < @lines && $lines[$i] =~ /^:\s+(.*)$/) {
        push @defs, $1;
        $i++;
        while ($i < @lines && $lines[$i] =~ /^\s{4,}(.+)$/) {
          $defs[-1] .= "\n" . $1;
          $i++;
        }
      }
      my @bits = ('<dl>', '<dt>' . _inline($term) . '</dt>');
      push @bits,   '<dd>' . _inline($_) . '</dd>' for @defs;
      push @bits,   '</dl>';
      push @blocks, join('', @bits);
      next;
    }

    # Internal blank lines are kept if surrounded by indents
    # (CommonMark, section 4.4).
    if ($line =~ /^(?:    |\t)(.*)$/) {
      my @body = ($1);
      $i++;
      while ($i < @lines) {
        if ($lines[$i] =~ /^(?:    |\t)(.*)$/) {
          push @body, $1;
          $i++;
        }
        elsif ($lines[$i] =~ /^\s*$/
          && $i + 1 < @lines
          && $lines[$i + 1] =~ /^(?:    |\t)/)
        {
          push @body, '';
          $i++;
        }
        else {
          last;
        }
      }
      push @blocks, Iczelia::Highlight::highlight(join("\n", @body), '');
      next;
    }

    # Stops at any block-level structure (so a paragraph never
    # eats a list, table, fence, heading, blockquote, etc.).
    my @para;
    my $sep_re = _table_sep_re();
    while ($i < @lines) {
      my $l = $lines[$i];
      last
        if $l =~ /^\s*$/
        || $l =~ /^```/
        || $l =~ /^#{1,6}\s/
        || $l =~ /^[-*_]{3,}\s*$/
        || $l =~ /^=+\s*$/
        || $l =~ /^-+\s*$/
        || $l =~ /^>/
        || $l =~ /^\s*([-*+]|\d+\.)\s+/
        || ($l =~ /\|/ && $i + 1 < @lines && $lines[$i + 1] =~ $sep_re);
      push @para, $l;
      $i++;
    }

    if (@para && $i < @lines && $lines[$i] =~ /^(=+|-+)\s*$/) {
      my $lvl  = $1 =~ /^=/ ? 1 : 2;
      my $text = _join_para(\@para);
      push @blocks, _atx_heading($lvl, $text);
      $i++;
      next;
    }

    if (@para) {
      push @blocks, "<p>" . _inline(_join_para(\@para)) . "</p>";
    }
    elsif ($line =~ /^[-*_]{3,}\s*$/) {
      push @blocks, "<hr>";
      $i++;
    }
    else {
      # Last resort: don't spin on a line nothing matched.
      push @blocks, "<p>" . _inline($line) . "</p>";
      $i++;
    }
  }

  my $html = join("\n", @blocks);

  if ($is_top) {
    if (@{$STATE->{fn_seq}}) {
      $html .= _render_footnotes_section();
    }

    # Hand math placeholders off to Render in a stable text form.
    $html =~ s/\x{E000}(\d+)\x{E001}/__MATH$1__/g;

    # Strip the <p> the paragraph pass may have wrapped around a
    # raw-HTML placeholder; block-level HTML can't live inside <p>.
    $html =~ s{<p>\s*\x{E400}(\d+)\x{E401}\s*</p>}{$raw_html[$1]}g;
    $html =~ s{\x{E400}(\d+)\x{E401}}{$raw_html[$1]}g;
  }
  return ($html, \@math);
}

# Trailing 2+ spaces become a PUA sentinel that escape_html passes
# through; _inline turns it into <br>. Other joins are soft-wraps.
sub _join_para {
  my ($lines) = @_;
  my @out;
  for my $i (0 .. $#$lines) {
    my $l    = $lines->[$i];
    my $hard = ($l =~ s/  +\z//) ? 1 : 0;
    if ($i == $#$lines) {
      push @out, $l;
    }
    elsif ($hard) {
      push @out, $l . "\x{E200}HARDBR\x{E201}";
    }
    else {
      push @out, $l . ' ';
    }
  }
  return join('', @out);
}

sub _atx_heading {
  my ($lvl, $text) = @_;
  my $id   = _heading_id($text);
  my $body = _inline($text);
  return sprintf
    '<h%d id="%s">%s <a class="ab-anchor" href="#%s" aria-label="link to %s">&#9095;</a></h%d>',
    $lvl, $id, $body, $id, $id, $lvl;
}

# Hugo-compatible heading slug.
sub _heading_id {
  my $s = shift // '';
  $s =~ s/`([^`]+)`/$1/g;
  $s =~ s/\*\*?([^\*]+)\*\*?/$1/g;
  $s =~ s/\[([^\]]+)\]\([^)]*\)/$1/g;
  $s =~ s/\[([^\]]+)\]\[[^\]]*\]/$1/g;
  $s = lc $s;
  $s =~ s/[^a-z0-9]+/-/g;
  $s =~ s/^-+|-+$//g;
  $s = substr($s, 0, 80) if length $s > 80;
  return length $s ? $s : 'section';
}

sub _list {
  my ($items, $is_ol) = @_;
  return '' unless @$items;
  my $top_tag = $is_ol ? 'ol' : 'ul';

  my @bits;
  my @stack;    # stack of { indent, tag, in_li }
  my $any_task = 0;

  my $close_li = sub {
    return unless @stack && $stack[-1]{in_li};
    push @bits, '</li>';
    $stack[-1]{in_li} = 0;
  };
  my $open_list = sub {
    my ($indent) = @_;
    push @bits, "<$top_tag>";
    push @stack, {indent => $indent, tag => $top_tag, in_li => 0};
  };
  my $close_list = sub {
    $close_li->();
    my $f = pop @stack;
    push @bits, "</$f->{tag}>";
  };

  $open_list->($items->[0][0]);
  for my $it (@$items) {
    my ($indent, $text) = @$it;

    # Pop nested lists until the top frame is at or below this indent.
    while (@stack > 1 && $stack[-1]{indent} > $indent) {
      $close_list->();
    }

    # Deeper indent opens a nested list inside the parent <li>.
    if ($stack[-1]{indent} < $indent) {
      $open_list->($indent);
    }
    $close_li->();

    my $li;
    if ($text =~ s/^\s*\[([ xX])\]\s+//) {
      my $checked = lc($1) eq 'x' ? 1 : 0;
      $any_task = 1;
      my $glyph = $checked ? '&#9745;' : '&#9744;';    # [x] [ ]
      my $cls =
        $checked
        ? 'ab-task ab-task-done'
        : 'ab-task ab-task-todo';
      $li = qq{<li class="$cls"><span class="ab-task-mark">$glyph</span> }
        . _inline($text);
    }
    else {
      $li = '<li>' . _inline($text);
    }
    push @bits, $li;
    $stack[-1]{in_li} = 1;
  }
  while (@stack) {$close_list->()}

  if ($any_task) {
    $bits[0] =~ s{^<$top_tag>}{<$top_tag class="ab-tasklist">};
  }
  return join('', @bits);
}

sub _table_sep_re {

  # At least one `|` so a pure-dash HR line can't masquerade as one.
  qr{^\s*\|?(?:\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?\s*$};
}

sub _table {
  my ($rows) = @_;
  my @parsed;
  for my $r (@$rows) {
    $r =~ s/^\s*\|//;
    $r =~ s/\|\s*$//;
    push @parsed,
      [map {my $c = $_; $c =~ s/^\s+//; $c =~ s/\s+$//; $c} split /\|/, $r];
  }
  my $head = shift @parsed;
  my $sep  = shift @parsed;

  # Separator-row alignment markers: :--- left, ---: right, :---: center.
  my @align;
  if (ref $sep eq 'ARRAY') {
    for my $cell (@$sep) {
      $cell //= '';
      $cell =~ s/^\s+//;
      $cell =~ s/\s+$//;
      if    ($cell =~ /^:-+:$/) {push @align, 'center'}
      elsif ($cell =~ /^-+:$/)  {push @align, 'right'}
      elsif ($cell =~ /^:-+$/)  {push @align, 'left'}
      else                      {push @align, undef}
    }
  }
  my $attr = sub {
    my $i = shift;
    my $a = $align[$i];
    return defined $a ? qq{ style="text-align:$a"} : '';
  };

  my @bits = ('<table>', '<thead><tr>');
  for my $i (0 .. $#$head) {
    push @bits, '<th' . $attr->($i) . '>' . _inline($head->[$i]) . '</th>';
  }
  push @bits, '</tr></thead>', '<tbody>';
  for my $r (@parsed) {
    push @bits, '<tr>';
    for my $i (0 .. $#$r) {
      push @bits, '<td' . $attr->($i) . '>' . _inline($r->[$i]) . '</td>';
    }
    push @bits, '</tr>';
  }
  push @bits, '</tbody></table>';
  return join('', @bits);
}

sub _inline {
  my ($s) = @_;
  return '' unless defined $s;

  my @held;
  my $hold = sub {
    my $html = shift;
    push @held, $html;
    sprintf "\x{E100}%d\x{E101}", $#held;
  };
  my $refs = ($STATE && $STATE->{refs}) || {};

  # Code spans first; insides escape but aren't re-parsed.
  # Equal-length backtick fences so `` a`b `` works. Per CommonMark,
  # one leading and one trailing space are stripped when both present
  # and the body has any non-space.
  $s =~ s{(?<!`)(`+)(?!`)((?:[^`]|`(?!\1))+?)(\1)(?!`)}{
        my $body = $2;
        if ($body =~ /^ / && $body =~ / $/ && $body =~ /\S/) {
            $body =~ s/^ //; $body =~ s/ $//;
        }
        $hold->('<code>' . escape_html($body) . '</code>')
    }ge;

  # Literal <br> (any case, optional self-close) becomes a hard break.
  # Common in GFM table cells; keep working without enabling raw HTML.
  $s =~ s{<br\s*/?>}{\x{E200}HARDBR\x{E201}}gi;

  # Images: ![alt](src) -> <img>; ![alt](src "cap") -> <figure>+cap.
  # Optional Pandoc-style trailing {.class .class} flags `.thumb` and
  # `.left` to float; both render as <figure class="ab-thumb"> or
  # <figure class="ab-thumb ab-thumb-left"> with text flowing around.
  $s =~
    s|!\[([^\]]*)\]\(\s*([^\s)]+)(?:\s+"([^"\n]*)")?\s*\)(?:\{([^}\n]*)\})?|
        my ($alt, $src, $cap, $attrs) = ($1, $2, $3, $4);
        $src = _ok_image($src) ? $src : '#';
        my $a = escape_html($alt);
        my $u = escape_html($src);
        my %cls = $attrs ? map { $_ => 1 } ($attrs =~ /\.([\w-]+)/g) : ();
        my $thumb_cls = $cls{thumb}
            ? ($cls{left} ? ' class="ab-thumb ab-thumb-left"'
                          : ' class="ab-thumb"')
            : '';
        if (defined $cap && length $cap) {
            my $c = escape_html($cap);
            $hold->(qq{<figure$thumb_cls><img src="$u" alt="$a" title="$c"><figcaption>$c</figcaption></figure>});
        } elsif ($thumb_cls) {
            $hold->(qq{<figure$thumb_cls><img src="$u" alt="$a"></figure>});
        } else {
            $hold->(qq{<img src="$u" alt="$a">});
        }
    |gex;

  # Must run before inline [text](url): the `][ref]` tail would
  # otherwise be half-eaten by the inline pattern.
  $s =~ s{\[([^\]]+)\]\[([^\]]*)\]}{
        my ($txt, $ref) = ($1, $2);
        $ref = $txt unless length $ref;
        my $r = $refs->{lc $ref};
        if ($r && _ok_url($r->{url})) {
            my $title = defined $r->{title} && length $r->{title}
                      ? qq{ title="} . escape_html($r->{title}) . qq{"} : '';
            $hold->('<a href="' . escape_html($r->{url}) . qq{"$title>}) . $txt . $hold->('</a>');
        } else {
            "[$txt][$ref]";
        }
    }ge;

  # [text](url): the URL may contain `)` so long as parens balance.
  # Pattern accepts nested `()` runs and stops at the first `)` that
  # would leave more closes than opens (Wikipedia-style URLs).
  $s =~ s{\[([^\]]+)\]\(((?:[^()\s]|\([^()\s]*\))+)\)}{
        my ($txt, $url) = ($1, $2);
        $url = _ok_url($url) ? $url : '#';
        $hold->('<a href="' . escape_html($url) . '">') . $txt . $hold->('</a>');
    }ge;

  # [ref] without the inline `(...)` / collapsed `[...]` tail.
  if (%$refs) {
    $s =~ s{\[([^\]]+)\](?![\(\[])}{
            my $txt = $1;
            my $r = $refs->{lc $txt};
            if ($r && _ok_url($r->{url})) {
                my $title = defined $r->{title} && length $r->{title}
                          ? qq{ title="} . escape_html($r->{title}) . qq{"} : '';
                $hold->('<a href="' . escape_html($r->{url}) . qq{"$title>}) . $txt . $hold->('</a>');
            } else {
                "[$txt]";
            }
        }ge;
  }

  # Footnote refs: [^id]
  $s =~ s{\[\^([^\]]+)\]}{ _hold_footnote_ref($hold, $1) }ge;

  # Bare URL autolink. Trailing `)` is dropped only when the URL
  # has more `)` than `(` (so Wikipedia-style /(scientist) URLs work).
  $s =~ s{(?<![\w/])(https?://[^\s<>"]+)}{
        my $url = $1;
        my $tail = '';
        while (length $url) {
            if ($url =~ /([.,;!?:])$/) {
                $tail = $1 . $tail; chop $url; next;
            }
            if (substr($url, -1) eq ')') {
                my $opens  = () = $url =~ /\(/g;
                my $closes = () = $url =~ /\)/g;
                if ($closes > $opens) {
                    $tail = ')' . $tail; chop $url; next;
                }
            }
            last;
        }
        $hold->('<a href="' . escape_html($url) . '">' . escape_html($url) . '</a>') . $tail;
    }ge;

  # Held HTML hides behind PUA sentinels so escape_html and the
  # emphasis regexes below don't touch it; restored at the end.
  $s = escape_html($s);

  $s =~ s{\x{E200}HARDBR\x{E201}}{<br>}g;

  $s =~ s{\*\*([^\*\n]+)\*\*}{<strong>$1</strong>}g;
  $s =~ s{(?<![A-Za-z0-9])__([^_\n]+)__(?![A-Za-z0-9])}{<strong>$1</strong>}g;
  $s =~ s{(?<![\*A-Za-z0-9])\*([^\*\n]+)\*(?![\*A-Za-z0-9])}{<em>$1</em>}g;
  $s =~ s{(?<![A-Za-z0-9_])_([^_\n]+)_(?![A-Za-z0-9_])}{<em>$1</em>}g;
  $s =~ s{~~([^~\n]+)~~}{<del>$1</del>}g;

  $s =~ s/\x{E100}(\d+)\x{E101}/$held[$1]/g;

  return $s;
}

# Pull `[^id]: body` (plus indented continuation lines). Returns
# { id => markdown }; rewrites $$src_ref with the bodies stripped.
sub _extract_footnotes {
  my ($src_ref) = @_;
  my %notes;
  my @lines = split /\n/, $$src_ref, -1;
  my @keep;
  my $i = 0;
  while ($i < @lines) {
    if ($lines[$i] =~ /^\s*\[\^([^\]\n]+)\]:\s*(.*)$/) {
      my ($id, $first) = ($1, $2);
      my @body = ($first);
      $i++;
      while ($i < @lines) {
        if ( $lines[$i] =~ /^\s*$/
          && $i + 1 < @lines
          && $lines[$i + 1] =~ /^(?:    |\t)/)
        {
          push @body, '';
          $i++;
        }
        elsif ($lines[$i] =~ /^(?:    |\t)(.*)$/) {
          push @body, $1;
          $i++;
        }
        else {
          last;
        }
      }
      $notes{$id} = join("\n", @body);
    }
    else {
      push @keep, $lines[$i++];
    }
  }
  $$src_ref = join("\n", @keep);
  return \%notes;
}

# Pull `[id]: url "title"` link reference definitions. Title is optional.
# Returns a hashref id -> { url, title } and rewrites $$src_ref.
sub _extract_link_refs {
  my ($src_ref) = @_;
  my %refs;
  $$src_ref =~ s{
        ^\s*
        \[ ( [^\]\n]+ ) \] :
        \s+
        ( <[^>]+> | \S+ )
        (?: \s+ (?: "([^"\n]*)" | '([^'\n]*)' | \(([^)\n]*)\) ) )?
        \s*
        (?: \n | \z )
    }{
        my $id    = lc $1;
        my $url   = $2;
        my $title = $3 // $4 // $5;
        $url =~ s/\A<|>\z//g;
        $refs{$id} = { url => $url, title => $title };
        '';
    }gmxe;
  return \%refs;
}

sub _hold_footnote_ref {
  my ($hold, $id) = @_;
  return "[^${id}]" unless $STATE && $STATE->{fnotes};
  return "[^${id}]" unless exists $STATE->{fnotes}{$id};
  my $idx = $STATE->{fn_idx}{$id};
  unless (defined $idx) {
    push @{$STATE->{fn_seq}}, $id;
    $idx = scalar @{$STATE->{fn_seq}};
    $STATE->{fn_idx}{$id} = $idx;
  }
  my $eid = escape_html($id);
  return $hold->(
    qq{<sup class="ab-fnref" id="fnref-$eid"><a href="#fn-$eid">[$idx]</a></sup>}
  );
}

sub _render_footnotes_section {
  my @bits = ('<section class="ab-footnotes"><hr><ol>');
  for my $id (@{$STATE->{fn_seq}}) {

    # Multi-line footnote bodies collapse to a single inline line.
    my $clean = $STATE->{fnotes}{$id} // '';
    $clean =~ s/\s+/ /g;
    my $eid  = escape_html($id);
    my $body = _inline($clean);
    push @bits, qq{<li id="fn-$eid"><p>$body }
      . qq{<a class="ab-fnback" href="#fnref-$eid" aria-label="back">&#8617;</a></p></li>};
  }
  push @bits, '</ol></section>';
  return join('', @bits);
}

sub _ok_url {
  my $u = shift;
  return 0 unless defined $u && length $u;
  return 1 if $u =~ m{^/[^/]} || $u eq '/' || $u =~ m{^\#};
  return 1 if $u =~ m{^https?://}i;
  return 1 if $u =~ m{^mailto:};
  return 0;
}

sub _ok_image {
  my $u = shift;
  return 1 if $u =~ m{^/media/};
  return 1 if $u =~ m{^/[^/]};
  return 1 if $u =~ m{^[^:]+\.(?:png|jpe?g|gif|svg|webp)$}i;
  return 0;
}

# Inline-only render: no block parsing, but **bold** / links still work.
# Used for short fields like vital-stats values.
sub render_inline {
  my ($s) = @_;
  return '' unless defined $s && length $s;
  return _inline($s);
}

1;
