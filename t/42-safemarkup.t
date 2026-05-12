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

use_ok('Iczelia::SafeMarkup');

sub r {my ($h) = Iczelia::SafeMarkup::render($_[0]); $h}
sub rm {my ($h, $m) = Iczelia::SafeMarkup::render($_[0]); ($h, $m)}

# Allowed
like r("hello"),         qr{<p>hello</p>},                       'paragraph';
like r("**bold** *em*"), qr{<strong>bold</strong>.*<em>em</em>}, 'emphasis';
like r("`x`"),           qr{<code>x</code>},                     'inline code';
like r("> quoted"),      qr{<blockquote>.*quoted.*</blockquote>}, 'blockquote';
like r("- a\n- b"),      qr{<ul><li>a</li><li>b</li></ul>},       'list';

# Links - only http(s), with rel attrs
like r("[hi](https://x.com)"), qr{rel="nofollow ugc noopener"},
  'link rel attrs';
like r("[hi](javascript:alert)"), qr{<p>hi</p>}, 'js scheme stripped to text';
like r("[hi](/internal)"),        qr{<p>hi</p>}, 'rel link stripped';

# Forbidden
unlike r("# H1"),               qr{<h1>}, 'no h1';
unlike r("## H2"),              qr{<h2>}, 'no h2';
unlike r("![a](/media/x.png)"), qr{<img}, 'no img';

# Math now allowed (rendered to placeholders, caller substitutes)
{
  my ($html, $math) = rm('hello $x^2$ world');
  like $html, qr{__MATH0__}, 'inline math placeholder';
  is scalar(@$math), 1,     'one math entry collected';
  is $math->[0][0],  0,     'inline (display=0)';
  is $math->[0][1],  'x^2', 'latex captured';
}
{
  my ($html, $math) = rm("Display: \$\$\\sum_{i=0}^n i\$\$ end.");
  like $html, qr{__MATH0__}, 'display math placeholder';
  is $math->[0][0], 1, 'display (display=1)';
}

# Raw HTML escaped
like r("<script>"), qr{&lt;script&gt;}, 'raw html escaped';

# Validation
my ($ok, $why) = Iczelia::SafeMarkup::validate('hi there');
is $ok, 1, 'valid body';
($ok, $why) = Iczelia::SafeMarkup::validate('');
is $ok,  0,       'empty rejected';
is $why, 'empty', 'empty reason';
($ok, $why) =
  Iczelia::SafeMarkup::validate('http://a.com http://b.com http://c.com');
is $ok,  0,                'three URLs rejected';
is $why, 'too many links', 'links reason';
($ok, $why) = Iczelia::SafeMarkup::validate('x' x 5000);
is $ok, 0, '5000 chars rejected';

# Math validation
($ok, $why) = Iczelia::SafeMarkup::validate('see $x+1$ and $$\sum y$$');
is $ok, 1, 'two math fragments OK';
($ok, $why) = Iczelia::SafeMarkup::validate('a $1$ b $2$ c $3$ d $4$ e $5$');
is $ok,  0,               '5 fragments rejected';
is $why, 'too much math', 'reason';
($ok, $why) = Iczelia::SafeMarkup::validate('$\def\x{\x\x}\x$');
is $ok,  0,                         '\\def rejected';
is $why, 'math: forbidden command', 'reason';
($ok, $why) = Iczelia::SafeMarkup::validate('$' . ('x' x 300) . '$');
is $ok,  0,                        'oversize fragment rejected';
is $why, 'math fragment too long', 'reason';
($ok, $why) = Iczelia::SafeMarkup::validate('$\loop\iftrue\repeat$');
is $ok, 0, '\\loop rejected';
($ok, $why) = Iczelia::SafeMarkup::validate('$\input{/etc/passwd}$');
is $ok, 0, '\\input rejected';

done_testing;
