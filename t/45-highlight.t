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
use utf8;
use Test::More;
binmode Test::More->builder->$_, ':utf8'
  for qw(output failure_output todo_output);

use_ok('Iczelia::Highlight');

ok Iczelia::Highlight::known('c'),           'C known';
ok Iczelia::Highlight::known('cpp'),         'cpp known';
ok Iczelia::Highlight::known('rust'),        'rust known';
ok Iczelia::Highlight::known('rs'),          'rust alias rs known';
ok Iczelia::Highlight::known('x86-intel'),   'x86-intel known';
ok Iczelia::Highlight::known('x86-att'),     'x86-att known';
ok Iczelia::Highlight::known('fasm'),        'fasm known';
ok Iczelia::Highlight::known('apl'),         'apl known';
ok Iczelia::Highlight::known('plain'),       'plain known';
ok !Iczelia::Highlight::known('moonscript'), 'unknown returns false';
ok !Iczelia::Highlight::known(''),           'empty rejected';
ok !Iczelia::Highlight::known(undef),        'undef rejected';

# All output is wrapped in <pre><code class="hl lang-X">...</code></pre>
my $h;

$h = Iczelia::Highlight::highlight('int x = 42; /* hi */', 'c');
like $h, qr{<pre class="hl lang-c"><code>},          'C wrapper class';
like $h, qr{<span class="hl-typ">int</span>},        'C: int -> typ';
like $h, qr{<span class="hl-num">42</span>},         'C: 42 -> num';
like $h, qr{<span class="hl-com">/\* hi \*/</span>}, 'C: block comment';

$h = Iczelia::Highlight::highlight('std::vector<int> v;', 'cpp');
like $h, qr{<span class="hl-cst">std</span>},    'C++: std -> cst';
like $h, qr{<span class="hl-typ">vector</span>}, 'C++: vector -> typ';
like $h, qr{<span class="hl-op">::</span>}, 'C++: :: as one operator token';

$h =
  Iczelia::Highlight::highlight(q{fn main() { let x: u32 = 0xff; }}, 'rust');
like $h, qr{<span class="hl-kw">fn</span>},    'rust: fn -> kw';
like $h, qr{<span class="hl-typ">u32</span>},  'rust: u32 -> typ';
like $h, qr{<span class="hl-num">0xff</span>}, 'rust: hex literal';

$h = Iczelia::Highlight::highlight("mov eax, 0xdead\n; nope", 'x86-intel');
like $h, qr{<span class="hl-kw">mov</span>},     'intel: mov -> kw';
like $h, qr{<span class="hl-reg">eax</span>},    'intel: eax -> reg';
like $h, qr{<span class="hl-num">0xdead</span>}, 'intel: hex literal';
like $h, qr{<span class="hl-com">; nope</span>}, 'intel: ; comment';

$h = Iczelia::Highlight::highlight('movq $0x100, %rax', 'x86-att');
like $h, qr{<span class="hl-kw">movq</span>},     'att: movq -> kw';
like $h, qr{<span class="hl-reg">%rax</span>},    'att: %rax -> reg';
like $h, qr{<span class="hl-num">\$0x100</span>}, 'att: \$imm -> num';

$h = Iczelia::Highlight::highlight(
  'format ELF executable
section ".text" executable
mov eax, 1', 'fasm'
);
like $h, qr{<span class="hl-pre">format</span>}, 'fasm: format directive';
like $h, qr{<span class="hl-typ">ELF</span>},    'fasm: ELF type';

$h = Iczelia::Highlight::highlight('avg ← +/⍵÷≢⍵', 'apl');
like $h, qr{<span class="hl-gly">\+</span>}, 'apl: + as glyph';
like $h, qr{<span class="hl-gly">/</span>},  'apl: / as glyph';
like $h, qr{<span class="hl-kw">⍵</span>},   'apl: ⍵ -> kw';
like $h, qr{<span class="hl-gly">÷</span>},  'apl: ÷ as glyph';
like $h, qr{<span class="hl-gly">≢</span>},  'apl: ≢ as glyph';

# HTML safety: angle-brackets in input must always be escaped
$h = Iczelia::Highlight::highlight('a < b && c > d', 'c');
unlike $h, qr{<span[^>]*>[^<]*<[^/!][^>]*>[^<]*</span>}, 'no nested raw tag';
like $h,   qr{&lt;},                                     'literal < escaped';
like $h,   qr{&gt;},                                     'literal > escaped';

# A would-be HTML injection attempt in source
$h = Iczelia::Highlight::highlight('"</span><script>x</script>"', 'c');
unlike $h, qr{<script>},      'injected <script> defanged';
like $h,   qr{&lt;/span&gt;}, 'injected </span> escaped';

# Unknown language -> plain (escaped, no tokenisation)
$h = Iczelia::Highlight::highlight('abc 123', 'no-such-lang');
like $h, qr{<pre class="hl"><code>abc 123</code></pre>}, 'unknown -> plain';

done_testing;
