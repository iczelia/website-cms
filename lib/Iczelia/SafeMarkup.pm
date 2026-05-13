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

package Iczelia::SafeMarkup;
use strict;
use warnings;
use Encode        ();
use Iczelia::Util qw(escape_html);
use Iczelia::Util ();
use Iczelia::MarkupCommon
  qw(hide_code_dollars restore_code_dollars extract_math);

# Restricted markdown for untrusted input (guestbook, admin replies).
# Allows paragraphs, emphasis, code, fenced blocks, lists,
# blockquotes, explicit http(s) links, and capped/blacklisted math.
# Returns ($html, \@math) for substitute_math() to materialise.

use constant MAX_NEST     => 8;
use constant MAX_MATH     => 4;      # per submission
use constant MAX_MATH_LEN => 256;    # per fragment

# TeX commands that can burn CPU, touch the filesystem, or escape
# the math sandbox. Tex.pm caps and sandboxes too; this is layered.
my $TEX_FORBIDDEN = qr/
    \\ (?:
        [egx]?def | let | futurelet | catcode | mathcode | delcode
      | sfcode | lccode | uccode
      | input | include | openin | closein | read
      | openout | closeout | write | immediate | special
      | loop | repeat
      | csname | endcsname | expandafter | noexpand
      | directlua | luaexec
      | new(?:command|environment|counter|if|count|toks|dimen|skip|muskip|fam|font)
      | renewcommand | providecommand | DeclareRobustCommand
      | count | toks | dimen | skip | muskip
      | advance | multiply | divide
      | the | meaning | string | jobname
      | message | errmessage | errhelp
      | usepackage | RequirePackage | documentclass
      | begin\s*\{\s*(?:lua|verb|alltt|tikz|asy|minted) \s*\}
      | (?:protect|relax) \b
    )
/x;

sub render {
  my ($src, $depth) = @_;
  $depth ||= 0;
  return ('', []) unless defined $src && length $src;
  return (Iczelia::Util::escape_html($src), []) if $depth > MAX_NEST;

  $src = _utf8($src) if $depth == 0;

  # Hard cap (caller should already enforce this; double-check).
  if (length($src) > 8192) {
    $src = substr($src, 0, 8192);
  }

  my @math;

  # Top-level only; recursive calls see PUA placeholders.
  if ($depth == 0) {
    $src = hide_code_dollars($src);
    $src = extract_math($src, \@math);
    $src = restore_code_dollars($src);
  }

  my @lines = split /\n/, $src, -1;
  my @blocks;
  my $i = 0;

  while ($i < @lines) {
    my $line = $lines[$i];

    if ($line =~ /^\s*$/) {$i++; next}

    if ($line =~ /^```\s*(\S*)\s*$/) {
      my $lang = $1 // '';
      my @body;
      $i++;
      while ($i < @lines && $lines[$i] !~ /^```\s*$/) {
        push @body, $lines[$i++];
      }
      $i++ if $i < @lines;
      require Iczelia::Highlight;

      # Untrusted: known tags only, others fall back to plain.
      my $tag =
        (length $lang && Iczelia::Highlight::known($lang)) ? $lang : 'plain';
      push @blocks, Iczelia::Highlight::highlight(join("\n", @body), $tag);
      next;
    }

    if ($line =~ /^>\s?(.*)$/) {
      my @body;
      while ($i < @lines && $lines[$i] =~ /^>\s?(.*)$/) {
        push @body, $1;
        $i++;
      }
      my ($inner) = render(join("\n", @body), $depth + 1);
      push @blocks, "<blockquote>" . $inner . "</blockquote>";
      next;
    }

    if ($line =~ /^\s*([-*+]|\d+\.)\s+(.+)$/) {
      my $is_ol = $1 =~ /\d/;
      my @items;
      while ($i < @lines && $lines[$i] =~ /^\s*([-*+]|\d+\.)\s+(.+)$/) {
        push @items, $2;
        $i++;
      }
      my $tag  = $is_ol ? 'ol' : 'ul';
      my $body = join('', map {'<li>' . _inline($_) . '</li>'} @items);
      push @blocks, "<$tag>$body</$tag>";
      next;
    }

    my @para;
    while ($i < @lines
      && $lines[$i] !~ /^\s*$/
      && $lines[$i] !~ /^```/
      && $lines[$i] !~ /^>/
      && $lines[$i] !~ /^\s*([-*+]|\d+\.)\s+/)
    {
      push @para, $lines[$i++];
    }
    my $text = join(' ', @para);
    push @blocks, '<p>' . _inline($text) . '</p>';
  }

  my $html = join("\n", @blocks);
  if ($depth == 0) {
    $html =~ s/\x{E000}(\d+)\x{E001}/__MATH$1__/g;
    return ($html, \@math);
  }
  return ($html, []);
}

sub _utf8 {
  my ($s) = @_;
  return '' unless defined $s;
  return $s if Encode::is_utf8($s);
  my $decoded = eval {Encode::decode('UTF-8', $s, Encode::FB_DEFAULT())};
  return defined $decoded ? $decoded : $s;
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

  $s =~ s{`([^`]+)`}{ $hold->('<code>' . escape_html($1) . '</code>') }ge;

  # http(s) only; <a> held so emphasis can't chew on the URL.
  $s =~ s{\[([^\]]+)\]\(([^)]+)\)}{
        my ($txt, $url) = ($1, $2);
        if ($url =~ m{^https?://}i) {
            $hold->('<a href="' . escape_html($url) . '" rel="nofollow ugc noopener">')
              . $txt . $hold->('</a>');
        } else {
            $txt
        }
    }ge;

  # Escape what remains (literal text + link inner text).
  $s = escape_html($s);

  # Emphasis on remaining text.
  $s =~ s{\*\*([^\*\n]+)\*\*}{<strong>$1</strong>}g;
  $s =~ s{(?<![\*A-Za-z0-9])\*([^\*\n]+)\*(?![\*A-Za-z0-9])}{<em>$1</em>}g;

  $s =~ s/\x{E100}(\d+)\x{E101}/$held[$1]/g;

  return $s;
}

# validate($body, \%opts) -> (ok, reason). Pre-scan caps and a TeX
# blacklist to reject hostile submissions before render() / Tex.
sub validate {
  my ($body, $opts) = @_;
  $opts ||= {};
  my $max = $opts->{max} // 4000;
  return (0, 'empty') unless defined $body && $body =~ /\S/;
  return (0, 'too long') if length $body > $max;
  my $url_count = () = $body =~ m{https?://}gi;
  return (0, 'too many links') if $url_count > 2;

  my @math;
  my $tmp = $body;
  while ($tmp =~ /\$\$ ( (?:[^\$\\]|\\.)*? ) \$\$/gx) {
    push @math, $1;
  }
  $tmp = $body;
  $tmp =~ s/\$\$ (?:[^\$\\]|\\.)*? \$\$//gx;    # strip display first
  while ($tmp =~ /(?<![\\\$]) \$ ( (?:[^\$\n\\]|\\.)+? ) \$/gx) {
    push @math, $1;
  }
  return (0, 'too much math') if @math > MAX_MATH;
  for my $frag (@math) {
    return (0, 'math fragment too long')
      if length($frag) > MAX_MATH_LEN;
    return (0, 'math: forbidden command')
      if $frag =~ $TEX_FORBIDDEN;
  }
  return (1, '');
}

1;
