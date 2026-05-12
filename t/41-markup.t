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

use strict;
use warnings;
use Test::More;

use_ok('Iczelia::Markup');

sub r {my ($html) = Iczelia::Markup::render($_[0]); $html}

# Headings
like r("## Hello"),
  qr{<h2 id="hello">Hello <a class="ab-anchor"[^>]*>&\#9095;</a></h2>},
  'h2 with anchor';
like r("# April 2026"),
  qr{<h1 id="april-2026">April 2026 <a class="ab-anchor"[^>]*>&\#9095;</a></h1>},
  'h1 with anchor';
like r("###### tiny"), qr{<h6 id="tiny">tiny }, 'h6 supported';

# Bare URL autolink
like r("see https://example.com/foo for more"),
  qr{see <a href="https://example.com/foo">https://example.com/foo</a> for more},
  'bare URL autolinked';
like r("(https://example.com/x)"),
  qr{<a href="https://example.com/x">}, 'autolink in parens';
like r("end of sentence: https://example.com/x."),
  qr{<a href="https://example.com/x">https://example.com/x</a>\.},
  'trailing punctuation outside link';

# Strikethrough
like r("~~gone~~"), qr{<del>gone</del>},                     'strikethrough';
like r("### Hi"),   qr{<h3 id="hi">Hi <a class="ab-anchor"}, 'h3 with anchor';

# Paragraphs
is r("a\nb\n\nc"), "<p>a b</p>\n<p>c</p>", 'paragraphs';

# Inline emphasis
like r("a **b** c"), qr{<strong>b</strong>}, 'strong';
like r("a *b* c"),   qr{<em>b</em>},         'em';
like r("a `b()` c"), qr{<code>b\(\)</code>}, 'code';

# Escape happens
like r("<x>"), qr{&lt;x&gt;}, 'escapes raw';

# Links
like r("[hi](https://x.com)"), qr{<a href="https://x.com">hi</a>}, 'http link';
like r("[hi](/about/)"),       qr{<a href="/about/">hi</a>},       'rel link';
like r("[hi](javascript:alert(1))"), qr{href="#"}, 'reject scheme';

# Lists
like r("- a\n- b\n"),   qr{<ul><li>a</li><li>b</li></ul>}, 'ul';
like r("1. a\n2. b\n"), qr{<ol><li>a</li><li>b</li></ol>}, 'ol';

# Code block. Markup::render now routes through Iczelia::Highlight, so
# the wrapper carries the highlighter's hl + lang-X classes for known
# languages and just `hl` for unknown ones.
{
  my $cb = r("```moonscript\nuse strict;\n```");
  like $cb, qr{<pre class="hl"><code>use strict;</code></pre>},
    'code block (unknown lang -> plain)';
  my $cb2 = r("```c\nint x = 0;\n```");
  like $cb2, qr{<pre class="hl lang-c"><code>},   'code block lang=c';
  like $cb2, qr{<span class="hl-typ">int</span>}, 'code block highlighted';
}

# Math placeholders
{
  my ($html, $math) = Iczelia::Markup::render('inline $x^2$ end');
  like $html, qr{__MATH0__}, 'inline math placeholder';
  is $math->[0][0], 0,     'inline display flag';
  is $math->[0][1], 'x^2', 'inline source';
}
{
  my ($html, $math) =
    Iczelia::Markup::render("display:\n\n\$\$ a^2 + b^2 \$\$\n");
  like $html, qr{__MATH0__}, 'display math placeholder';
  is $math->[0][0], 1, 'display flag';
}

# $...$ inside fenced code is not math.
{
  my ($html, $math) = Iczelia::Markup::render(
    "```c\nint _\$(_\$\$,_\$_) { return _\$\$ + _\$_; }\n```\n");
  is scalar(@$math), 0, 'no math captured from fenced code block';
  like $html, qr{<pre class="hl}, 'fenced code rendered';
  my $stripped = $html;
  $stripped =~ s{<[^>]+>}{}g;
  like $stripped, qr{int _\$\(_\$\$,_\$_\)},
    'literal dollars survive into code';
}

# $...$ inside an inline code span is not math either.
{
  my ($html, $math) = Iczelia::Markup::render('see `$a$ and $b$` literal');
  is scalar(@$math), 0, 'no math captured from inline code';
  like $html, qr{<code>\$a\$ and \$b\$</code>}, 'inline code preserved';
}

# GFM table without leading/trailing pipes.
{
  my $h =
    r("Letter | Frequency\n-------|----------\n a     | 100\n b     | 50\n");
  like $h, qr{<table>},              'GFM table without leading | rendered';
  like $h, qr{<th[^>]*>Letter</th>}, 'header cell';
  like $h, qr{<td[^>]*>a</td>},      'body cell trimmed';
}

# Bullet list immediately after a paragraph (no blank line).
{
  my $h = r("intro line\n- item one\n- item two\n");
  like $h, qr{<p>intro line</p>}, 'paragraph terminated by list';
  like $h, qr{<ul>.*<li>.*item one.*<li>.*item two.*</ul>}s, 'list rendered';
}

# Ordered list immediately after a paragraph (dictionary entry style).
{
  my $h = r("term\n1. first def\n2. second def\n");
  like $h, qr{<p>term</p>}, 'paragraph stops at "1." marker';
  like $h, qr{<ol>.*<li>.*first def.*<li>.*second def.*</ol>}s, 'ol rendered';
}

# Autolink with balanced parens (Wikipedia-style).
{
  my $h = r('see https://en.wikipedia.org/wiki/Foo_(bar) for more');
  like $h, qr{href="https://en\.wikipedia\.org/wiki/Foo_\(bar\)"},
    'balanced parens kept inside URL';
}

# Image with {.thumb} renders as a floated <figure>.
{
  my $h = r('![alt](/media/x.png){.thumb}');
  like $h,
    qr{<figure class="ab-thumb"><img src="/media/x\.png" alt="alt"></figure>},
    'plain thumb';
  my $h2 = r('![alt](/media/x.png "cap"){.thumb}');
  like $h2,
    qr{<figure class="ab-thumb"><img src="/media/x\.png" alt="alt" title="cap"><figcaption>cap</figcaption></figure>},
    'thumb with caption';
  my $h3 = r('![alt](/media/x.png){.thumb .left}');
  like $h3, qr{<figure class="ab-thumb ab-thumb-left">}, 'thumb floated left';
  my $h4 = r('![alt](/media/x.png)');
  unlike $h4, qr{ab-thumb}, 'plain image has no thumb class';
}

# Inline math close-$ followed by a digit is NOT math (Pandoc rule).
{
  my ($html, $math) = Iczelia::Markup::render('We have $x$2 here.');
  is scalar(@$math), 0, '$x$2 is text, not math';
  like $html, qr{\$x\$2}, 'literal preserved';
}
{
  my ($html, $math) = Iczelia::Markup::render('See $x$ now.');
  is scalar(@$math), 1, '$x$ followed by space is math';
}

# Equal-length backtick fence: `` a`b `` should become <code>a`b</code>.
{
  my $h = r('`` a`b ``');
  like $h, qr{<code>a`b</code>}, 'double-backtick code with inner backtick';
}

# Bold marker on a single line stops at the line end (defense in depth
# even though the paragraph collector joins soft-wraps with a space).
{
  my $h = Iczelia::Markup::render_inline("a __open\nb __closed__ c");
  like $h,   qr{<strong>closed</strong>}, '__closed__ becomes bold';
  unlike $h, qr{<strong>open[^<]*closed}, 'no cross-line __ pair';
}

# [text](url) keeps balanced parens (Wikipedia-style URLs).
{
  my $h = r('see [Foo](https://en.wikipedia.org/wiki/Foo_(bar))');
  like $h, qr{href="https://en\.wikipedia\.org/wiki/Foo_\(bar\)"},
    'inline link keeps balanced (bar)';
  like $h, qr{>Foo</a>}, 'inline-link text preserved';
}

# Stray single backticks inside two separate fenced blocks must not
# pair across the boundary and swallow `$math$` in the prose between.
{
  my $src =
      "```c\nf(\"x`y\");\n```\n\n"
    . "Some \$\\lambda(n)\$ here.\n\n"
    . "```c\ng(\"a`b\");\n```\n";
  my ($html, $math) = Iczelia::Markup::render($src);
  is scalar(@$math), 1,             'math captured between two fenced blocks';
  is $math->[0][1],  '\\lambda(n)', 'math fragment intact';
}

# Nested lists (2-space indent inside parent <li>).
{
  my $h = r("- A\n  - B1\n  - B2\n- C\n");
  like $h, qr{<ul><li>A<ul><li>B1</li><li>B2</li></ul></li><li>C</li></ul>},
    'two-deep nested unordered list';
}

# Bare <br> in paragraph and table cell becomes a hard break.
{
  my $h = r("first<br>second");
  like $h, qr{<p>first<br>second</p>},
    '<br> renders as line break in paragraph';
}
{
  my $h = r("| a | b |\n|---|---|\n| line1<br>line2 | end |\n");
  like $h, qr{<td[^>]*>line1<br>line2</td>}, '<br> renders inside table cell';
}

# Autolink trailing punctuation outside the link.
{
  my $h = r('see https://example.com/x.html. also https://example.com/y).');
  like $h,
    qr{href="https://example\.com/x\.html"[^>]*>https://example\.com/x\.html</a>\.},
    'trailing dot stripped from URL';
  like $h,
    qr{href="https://example\.com/y"[^>]*>https://example\.com/y</a>\)\.},
    'unbalanced trailing ) stripped from URL';
}

# Blockquote
like r("> hello\n> world"), qr{<blockquote>.*hello world.*</blockquote>}s,
  'blockquote';

# HR
like r("---"), qr{<hr>}, 'hr';

# Inline only render
is Iczelia::Markup::render_inline("a **b** c"),
  "a <strong>b</strong> c",
  'inline-only render';

# Image whitelist
like r("![x](/media/a.png)"), qr{<img src="/media/a.png"}, 'media image ok';
like r("![x](https://evil.example/a.png)"), qr{src="#"},
  'external image rejected';

# Setext headings
{
  my $h = r("Title text\n=========\n");
  like $h, qr{<h1 id="title-text">}, 'setext h1';
  my $h2 = r("Sub text\n--------\n");
  like $h2, qr{<h2 id="sub-text">}, 'setext h2';
}

# Hard line breaks (two spaces at EOL)
{
  my $h = r("first  \nsecond");
  like $h, qr{<p>first<br>second</p>}, 'hard line break';
  my $h2 = r("first\nsecond");
  like $h2, qr{<p>first second</p>}, 'soft wrap (no double-space)';
}

# Indented code block (4-space)
{
  my $h = r("normal paragraph\n\n    indented = code;\n    next_line;\n");
  like $h, qr{<pre class="hl[^"]*"><code>indented = code;\nnext_line;},
    'indented code at block scope';
}

# Reference-style links
{
  my $h = r(
    "see [the docs][docs] for more.\n\n[docs]: https://iczelia.net/about/ \"about page\""
  );
  like $h,
    qr{<a href="https://iczelia.net/about/" title="about page">the docs</a>},
    'ref-style link with title';
  my $h2 = r("see [the docs][] now.\n\n[the docs]: https://iczelia.net/cv/");
  like $h2, qr{<a href="https://iczelia.net/cv/">the docs</a>},
    'collapsed ref-style';
}

# Footnotes
{
  my $h = r(
    "a sentence[^one] and another[^two].\n\n[^one]: first note.\n[^two]: second note."
  );
  like $h,
    qr{<sup class="ab-fnref" id="fnref-one"><a href="#fn-one">\[1\]</a></sup>},
    'footnote ref 1';
  like $h,
    qr{<sup class="ab-fnref" id="fnref-two"><a href="#fn-two">\[2\]</a></sup>},
    'footnote ref 2';
  like $h, qr{<section class="ab-footnotes">}, 'footnote section';
  like $h, qr{<li id="fn-one"><p>first note},  'footnote 1 body';
  like $h, qr{<li id="fn-two"><p>second note}, 'footnote 2 body';
}

# Definition list
{
  my $h = r(
    "APL\n: a notation as a tool of thought.\n: pronounced \"a programming language\""
  );
  like $h, qr{<dl><dt>APL</dt>},                           'dl with term';
  like $h, qr{<dd>a notation as a tool of thought\.</dd>}, 'dd #1';
  like $h, qr{<dd>pronounced },                            'dd #2';
}

# Task list
{
  my $h = r("- [ ] open\n- [x] done\n- normal item\n");
  like $h, qr{<ul class="ab-tasklist">}, 'tasklist class';
  like $h,
    qr{<li class="ab-task ab-task-todo"><span class="ab-task-mark">&#9744;</span>},
    'unchecked';
  like $h,
    qr{<li class="ab-task ab-task-done"><span class="ab-task-mark">&#9745;</span>},
    'checked';
}

# Tables with alignment
{
  my $h = r("| a | b | c |\n|:--|--:|:-:|\n| 1 | 2 | 3 |\n");
  like $h, qr{<th style="text-align:left">a</th>},   'th left aligned';
  like $h, qr{<th style="text-align:right">b</th>},  'th right aligned';
  like $h, qr{<th style="text-align:center">c</th>}, 'th center aligned';
  like $h, qr{<td style="text-align:left">1</td>},   'td inherits left';
  like $h, qr{<td style="text-align:right">2</td>},  'td inherits right';
  like $h, qr{<td style="text-align:center">3</td>}, 'td inherits center';
}

done_testing;
