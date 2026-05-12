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

package Iczelia::Highlight;
use strict;
use warnings;
use utf8;    # APL primitive glyphs in the rule list are codepoints, not bytes.
use Iczelia::Util qw(escape_html);

# Pure-Perl tokenizer; rules are ordered specific-first.
# Each {type, re} emits <span class="hl-$type">...</span>.

our $VERSION = '0.1';

my %LANG;
my %ALIAS;

# Admin-defined languages, refreshed on (max(version), count) change.
our $DB;
our $LOADED_VERSION = -1;
our %DB_LANG;
our %DB_ALIAS;

# Combined-regex cache for the tokenizer; cleared whenever DB-defined
# languages refresh so old rule-array references don't pin entries.
my %_COMBINED;

sub set_db {
  my ($db) = @_;
  $DB             = $db;
  $LOADED_VERSION = -1;
  %DB_LANG        = ();
  %DB_ALIAS       = ();
}

# Updates bump max(version); deletes/inserts change count.
sub _db_version_stamp {
  return -1 unless $DB;
  my $r = eval {
    $DB->row(
      q{SELECT COALESCE(MAX(version),0) AS v, COUNT(*) AS n
                     FROM highlight_langs}
    );
  };
  return -1 if $@ || !$r;
  return ($r->{v} || 0) * 1_000_003 + ($r->{n} || 0);
}

# Built-in names/aliases always win; colliding DB rows are dropped.
sub _refresh_db_langs {
  return unless $DB;
  my $cur = _db_version_stamp();
  return if $cur == $LOADED_VERSION;
  %DB_LANG  = ();
  %DB_ALIAS = ();

  # Drop the combined-regex cache; old DB-rule arrayrefs are gone
  # and would otherwise leak one entry per language per refresh.
  %_COMBINED = ();
  my $rows = eval {$DB->all('SELECT * FROM highlight_langs')} || [];
  for my $r (@$rows) {
    my $name = lc($r->{name} // '');
    next unless length $name;
    next if exists $LANG{$name};       # built-in wins
    next if exists $DB_LANG{$name};    # uniqueness within DB
    my $rules = _build_db_rules($r);
    $DB_LANG{$name} = {
      name    => $r->{name},
      aliases => [split /\s*,\s*/, ($r->{aliases} // '')],
      rules   => $rules,
    };
  }

  # First-defined alias wins; admin langs can't shadow built-ins.
  for my $name (keys %DB_LANG) {
    $DB_ALIAS{$name} = $name;
    for my $a (@{$DB_LANG{$name}{aliases}}) {
      my $la = lc $a;
      next unless length $la;
      next if exists $ALIAS{$la};
      next if exists $DB_ALIAS{$la};
      $DB_ALIAS{$la} = $name;
    }
  }
  $LOADED_VERSION = $cur;
}

# All untrusted input is quotemeta'd + shape-validated so admin
# language rows can't smuggle regex metachars into a compiled rule.
sub _build_db_rules {
  my ($r) = @_;
  my @rules;

  # Block comments need to fire before line comments (greedier).
  my $bc = $r->{block_comment} // '';
  if ($bc =~ /^\s*(\S{1,3})\s+(\S{1,3})\s*$/) {
    my ($o, $c) = ($1, $2);
    my $re = qr{\Q$o\E.*?\Q$c\E}s;
    push @rules, {type => 'com', re => $re};
  }
  my $lc = $r->{line_comment} // '';
  if ($lc =~ /^[[:punct:]]{1,3}$/ && $lc =~ /^[\x21-\x7e]+$/) {
    my $re = qr{\Q$lc\E[^\n]*};
    push @rules, {type => 'com', re => $re};
  }
  my $sq = $r->{string_quotes} // '"';
  for my $q (split //, $sq) {
    next unless $q =~ /^[[:punct:]]$/ && $q =~ /^[\x21-\x7e]$/;
    my $re = qr{ \Q$q\E (?:[^\Q$q\E\\\n]|\\.)* \Q$q\E }x;
    push @rules, {type => 'str', re => $re};
  }

  # Word-list rules: tokens must match \w[\w:-]{0,63}.
  for my $field (
    ['kw',  $r->{keywords}],
    ['typ', $r->{types}],
    ['cst', $r->{builtins}],
    )
  {
    my ($tag, $src) = @$field;
    my @t;
    for my $tok (split /[\s,]+/, ($src // '')) {
      next unless length $tok;
      next unless $tok =~ /^[\w][\w:-]{0,63}$/;
      push @t, $tok;
    }
    next unless @t;

    # Longest-first.
    @t = sort {length($b) <=> length($a) || $a cmp $b} @t;
    my $alt = join '|', map {quotemeta} @t;
    my $re  = qr{\b(?:$alt)\b};
    push @rules, {type => $tag, re => $re};
  }

  # Generic number + identifier so partial definitions still do something.
  push @rules, {type => 'num', re => qr{\b\d+(?:\.\d+)?\b}};
  push @rules, {type => 'id',  re => qr{[A-Za-z_]\w*}};
  return \@rules;
}

# C-family number literals (0x..., 0b..., decimals, exponents, suffixes).
my $CNUMBER = qr{
    \b (?:
          0 [xX] [0-9a-fA-F]+ (?:\.[0-9a-fA-F]+)? (?:[pP][-+]?\d+)?
        | 0 [bB] [01]+
        | 0 [0-7]*
        | \d+ (?:\.\d+)? (?:[eE][-+]?\d+)?
        | \. \d+ (?:[eE][-+]?\d+)?
      )
      [uUlLfFiIzZ]*
    \b
}x;

my $CSTR           = qr{ " (?:[^"\\\n]|\\.)* " }x;
my $CCHAR          = qr{ ' (?:[^'\\\n]|\\.)* ' }x;
my $CCOMMENT_BLOCK = qr{ /\* .*? \*/ }sx;
my $CCOMMENT_LINE  = qr{ // [^\n]* }x;

$LANG{c} = {
  name    => 'C',
  aliases => [qw(c h)],
  rules   => [
    {type => 'com', re => $CCOMMENT_BLOCK},
    {type => 'com', re => $CCOMMENT_LINE},
    {type => 'str', re => $CSTR},
    {type => 'chr', re => $CCHAR},
    {type => 'pre', re => qr{ (?:^|(?<=\n)) [ \t]* \# (?:[^\n\\]|\\.)* }x},
    {type => 'num', re => $CNUMBER},
    {
      type => 'kw',
      re   => qr{\b(?:
            if|else|while|for|do|switch|case|default|break|continue|return|goto|
            sizeof|typedef|struct|union|enum|extern|static|const|volatile|register|
            auto|inline|restrict|_Bool|_Complex|_Imaginary|_Atomic|_Thread_local|
            _Generic|_Static_assert|_Noreturn|_Alignas|_Alignof
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            void|char|short|int|long|float|double|signed|unsigned|
            size_t|ssize_t|ptrdiff_t|intptr_t|uintptr_t|off_t|time_t|
            int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|uint32_t|uint64_t|
            FILE|bool|wchar_t|va_list
        )\b}x
    },
    {type => 'cst', re => qr{\b(?:NULL|true|false|TRUE|FALSE|EOF)\b}},
    {type => 'op',  re => qr{[-+*/%=<>!&|^~?:]+}},
    {type => 'pn',  re => qr{[(){}\[\];,.]}},
    {type => 'id',  re => qr{[A-Za-z_]\w*}},
  ],
};

$LANG{cpp} = {
  name    => 'C++',
  aliases => [qw(cpp c++ cxx hpp)],
  rules   => [
    {type => 'com', re => $CCOMMENT_BLOCK},
    {type => 'com', re => $CCOMMENT_LINE},

    # Raw string literal: R"delim(...)delim"
    {type => 'str', re => qr{R"([^()\\\s]{0,16})\(.*?\)\g{-1}"}s},
    {type => 'str', re => $CSTR},
    {type => 'chr', re => $CCHAR},
    {type => 'pre', re => qr{ (?:^|(?<=\n)) [ \t]* \# (?:[^\n\\]|\\.)* }x},
    {type => 'num', re => $CNUMBER},
    {
      type => 'kw',
      re   => qr{\b(?:
            alignas|alignof|and|and_eq|asm|auto|break|case|catch|class|co_await|
            co_return|co_yield|compl|concept|const|consteval|constexpr|constinit|
            const_cast|continue|decltype|default|delete|do|dynamic_cast|else|enum|
            explicit|export|extern|final|for|friend|goto|if|inline|mutable|
            namespace|new|noexcept|not|not_eq|operator|or|or_eq|override|private|
            protected|public|register|reinterpret_cast|requires|return|sizeof|
            static|static_assert|static_cast|struct|switch|template|this|
            thread_local|throw|try|typedef|typeid|typename|union|using|virtual|
            volatile|while|xor|xor_eq
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            void|char|char8_t|char16_t|char32_t|wchar_t|short|int|long|float|
            double|signed|unsigned|bool|size_t|ssize_t|ptrdiff_t|nullptr_t|
            intptr_t|uintptr_t|int8_t|int16_t|int32_t|int64_t|uint8_t|uint16_t|
            uint32_t|uint64_t|string|string_view|vector|array|map|unordered_map|
            set|unordered_set|pair|tuple|optional|variant|shared_ptr|unique_ptr|
            weak_ptr|function|span|FILE|va_list
        )\b}x
    },
    {type => 'cst', re => qr{\b(?:nullptr|true|false|NULL|EOF|std)\b}},
    {
      type => 'op',
      re   =>
        qr{(?:::|->\*|->|\.\*|<<=?|>>=?|<=>|<=|>=|==|!=|&&|\|\||[-+*/%=<>!&|^~?:])}
    },
    {type => 'pn', re => qr{[(){}\[\];,.]}},
    {type => 'id', re => qr{[A-Za-z_]\w*}},
  ],
};

$LANG{java} = {
  name    => 'Java',
  aliases => [qw(java)],
  rules   => [
    {type => 'com', re => $CCOMMENT_BLOCK},
    {type => 'com', re => $CCOMMENT_LINE},

    # Text block """ ... """ (Java 15+).
    {type => 'str', re => qr{"""(?:[^\\]|\\.)*?"""}s},
    {type => 'str', re => $CSTR},
    {type => 'chr', re => $CCHAR},

    # Annotations: @Identifier, optional .qualified, optional (args).
    {type => 'attr', re => qr{ @ [A-Za-z_]\w* (?:\.[A-Za-z_]\w*)* }x},

    # Numbers: hex, bin, decimal, with _ separators, suffixes l/L/f/F/d/D.
    {
      type => 'num',
      re   => qr{
            \b 0[xX][\da-fA-F_]+ [lL]? \b
          | \b 0[bB][01_]+ [lL]? \b
          | \b \d[\d_]* (?: \.\d[\d_]* )? (?:[eE][-+]?\d+)? [lLfFdD]? \b
        }x
    },
    {
      type => 'kw',
      re   => qr{\b(?:
            abstract|assert|break|case|catch|class|const|continue|default|do|
            else|enum|exports|extends|final|finally|for|goto|if|implements|
            import|instanceof|interface|module|native|new|non-sealed|open|
            opens|package|permits|private|protected|provides|public|record|
            requires|return|sealed|static|strictfp|super|switch|synchronized|
            this|throw|throws|to|transient|transitive|try|uses|var|volatile|
            while|with|yield
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            void|boolean|byte|short|int|long|float|double|char|
            String|Object|Integer|Long|Short|Byte|Float|Double|Boolean|
            Character|Number|Math|System|Class|Throwable|Exception|
            RuntimeException|Error|List|ArrayList|LinkedList|Map|HashMap|
            TreeMap|LinkedHashMap|Set|HashSet|TreeSet|Collection|Iterable|
            Iterator|Optional|Stream|Comparable|Comparator|Runnable|Thread
        )\b}x
    },
    {type => 'cst', re => qr{\b(?:true|false|null)\b}},
    {
      type => 'op',
      re   =>
        qr{(?:>>>=?|<<=?|>>=?|->|::|\.\.\.|==|!=|<=|>=|&&|\|\||\+\+|--|[-+*/%=<>!&|^~?:])}
    },
    {type => 'pn', re => qr{[(){}\[\];,.]}},
    {type => 'id', re => qr{[A-Za-z_]\w*}},
  ],
};

$LANG{rust} = {
  name    => 'Rust',
  aliases => [qw(rust rs)],
  rules   => [
    {
      type => 'com',
      re   => qr{ /\* (?: (?> [^/*]+ ) | /(?!\*) | \*(?!/) )* \*/ }sx
    },
    {type => 'com', re => $CCOMMENT_LINE},

    # Attributes #[...]
    {type => 'attr', re => qr{ \# !? \[ (?:[^\[\]\n]|\[[^\]]*\])* \] }x},

    # Raw strings r"..." r#"..."# r##"..."##
    {type => 'str', re => qr{ r (\#*) " .*? " \g{-1} }sx},
    {type => 'str', re => qr{ b? " (?:[^"\\]|\\.)* " }sx},

    # Byte/char literals 'a' '\n' '\u{1F600}' b'a' (or lifetime 'foo)
    {
      type => 'chr',
      re   =>
        qr{ b? ' (?: \\(?:[\\'"nrt0]|x[0-9A-Fa-f]{2}|u\{[0-9A-Fa-f]{1,6}\}) | [^'\\] ) ' }x
    },
    {type => 'lt', re => qr{ ' (?:[A-Za-z_]\w*|static) (?!\w|') }x},
    {
      type => 'num',
      re   => qr{
            \b (?:
                0x[0-9A-Fa-f_]+ | 0o[0-7_]+ | 0b[01_]+
              | \d[\d_]* (?:\.\d[\d_]*)? (?:[eE][-+]?\d[\d_]*)?
            )
            (?: [iu](?:8|16|32|64|128|size) | f(?:32|64) )?
            \b
        }x
    },
    {
      type => 'kw',
      re   => qr{\b(?:
            as|async|await|box|break|const|continue|crate|do|dyn|else|enum|extern|
            false|fn|for|if|impl|in|let|loop|match|mod|move|mut|pub|ref|return|
            Self|self|static|struct|super|trait|true|try|type|union|unsafe|use|
            where|while|yield
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            i8|i16|i32|i64|i128|isize|u8|u16|u32|u64|u128|usize|f32|f64|bool|char|
            str|String|Vec|Option|Result|Box|Rc|Arc|Cell|RefCell|HashMap|HashSet|
            BTreeMap|BTreeSet|VecDeque
        )\b}x
    },
    {type => 'cst', re => qr{\b(?:None|Some|Ok|Err|true|false)\b}},

    # Macro invocation: ident! or ident!{ } / ident!( )
    {type => 'mac', re => qr{ [a-zA-Z_]\w* ! }x},
    {
      type => 'op',
      re   =>
        qr{(?:=>|::|->|\.\.\.?|<<=?|>>=?|==|!=|<=|>=|&&|\|\||[-+*/%=<>!&|^~?])}
    },
    {type => 'pn', re => qr{[(){}\[\];,.]}},
    {type => 'id', re => qr{[A-Za-z_]\w*}},
  ],
};

my $X86_REGS_FULL = qr{\b(?:
    rax|rbx|rcx|rdx|rsi|rdi|rbp|rsp|r8|r9|r10|r11|r12|r13|r14|r15|
    r8d|r9d|r10d|r11d|r12d|r13d|r14d|r15d|
    r8w|r9w|r10w|r11w|r12w|r13w|r14w|r15w|
    r8b|r9b|r10b|r11b|r12b|r13b|r14b|r15b|
    eax|ebx|ecx|edx|esi|edi|ebp|esp|eip|
    ax|bx|cx|dx|si|di|bp|sp|ip|
    al|ah|bl|bh|cl|ch|dl|dh|spl|bpl|sil|dil|
    cs|ds|es|fs|gs|ss|
    cr0|cr2|cr3|cr4|cr8|
    dr0|dr1|dr2|dr3|dr6|dr7|
    st[0-7]?|
    mm[0-7]|xmm[0-9]+|ymm[0-9]+|zmm[0-9]+
)\b}x;

my $X86_INSTRS = qr{\b(?:
    mov|movs[bwlqbq]?|movzx|movsx|movsxd|cmov[a-z]+|
    add|adc|sub|sbb|imul|mul|idiv|div|inc|dec|neg|not|
    and|or|xor|shl|shr|sal|sar|rol|ror|rcl|rcr|bt|bts|btr|btc|bsr|bsf|
    cmp|test|push|pop|pusha|popa|pushf|popf|pushfq|popfq|
    jmp|j[a-z]+|call|ret|retn|retf|iret|iretd|iretq|loop|loope|loopne|
    int|int3|into|hlt|nop|cpuid|rdtsc|rdmsr|wrmsr|wait|fwait|lock|rep|repe|repne|repnz|repz|
    cld|std|cli|sti|clc|stc|cmc|
    lea|enter|leave|
    in|out|ins[bwl]|outs[bwl]|cmps[bwl]|scas[bwl]|lods[bwl]|stos[bwl]|
    syscall|sysret|sysenter|sysexit|swapgs|
    fld|fst|fstp|fadd|fsub|fmul|fdiv|fcom|fucom|fxch|fninit|fldz|fld1|fldpi|
    movaps|movups|movsd|movss|addps|subps|mulps|divps|sqrtps|cmpps|
    pxor|por|pand|pandn|pcmpeqb|pcmpgtb|paddb|psubb|psllw|psrlw|pmovmskb|
    vmovaps|vmovups|vbroadcasts[sd]|vpermd|vpbroadcastb|vpgatherdd
)\b}x;

my $X86_DIRECT = qr{\b(?:
    section|segment|global|extern|public|private|
    db|dw|dd|dq|dt|do|dy|dz|
    resb|resw|resd|resq|rest|reso|resy|resz|
    times|equ|incbin|include|default|cpu|bits|use16|use32|use64|
    align|alignb|absolute|struc|endstruc|istruc|iend|at|
    byte|word|dword|qword|tword|oword|yword|zword|ptr|near|far|short
)\b}xi;

$LANG{'x86-intel'} = {
  name    => 'x86 (Intel)',
  aliases => [qw(x86 nasm intel asm asm-intel)],
  rules   => [
    {type => 'com', re => qr{;[^\n]*}},
    {type => 'str', re => $CSTR},
    {type => 'str', re => qr{ ' (?:[^'\\\n]|\\.)* ' }x},
    {
      type => 'pre',
      re   => qr{ (?:^|(?<=\n)) [ \t]* %[a-z][\w]* (?:[ \t]+[^\n]*)? }x
    },

    # 1234h / 0FFh / 0x... / 0b... / decimals
    {type => 'num', re => qr{ \b 0[xX][0-9A-Fa-f]+ \b }x},
    {type => 'num', re => qr{ \b [0-9][0-9A-Fa-f]*[hH] \b }x},
    {type => 'num', re => qr{ \b 0[bB][01]+ \b }x},
    {type => 'num', re => qr{ \b \d+ \b }x},

    # Label at column 0:  label:
    {type => 'lbl', re => qr{ (?:^|(?<=\n)) [ \t]* [.\w\$]+ : }x},
    {type => 'reg', re => $X86_REGS_FULL},
    {type => 'kw',  re => $X86_INSTRS},
    {type => 'typ', re => $X86_DIRECT},
    {type => 'op',  re => qr{[-+*/%=<>!&|^~?:]+}},
    {type => 'pn',  re => qr{[(){}\[\],]}},
    {type => 'id',  re => qr{[.\w\$]+}},
  ],
};

$LANG{'x86-att'} = {
  name    => 'x86 (AT&T)',
  aliases => [qw(att gas asm-att gnuas)],
  rules   => [
    {type => 'com', re => qr{ /\* .*? \*/ }sx},
    {type => 'com', re => qr{ //[^\n]* }x},
    {type => 'com', re => qr{ \#[^\n]* }x},       # gas line comment
    {type => 'str', re => $CSTR},

    # %register   (eax, %rdi, %xmm0, etc.)
    {type => 'reg', re => qr{ % \w+ }x},

    # $immediate  ($0x100, $42)
    {type => 'num', re => qr{ \$ [-+]? (?: 0[xX][0-9A-Fa-f]+ | \d+ ) }x},
    {type => 'num', re => qr{ \b 0[xX][0-9A-Fa-f]+ \b }x},
    {type => 'num', re => qr{ \b \d+ \b }x},

    # gas directives  .section .globl .align .data .text ...
    {type => 'pre', re => qr{ (?:^|(?<=\n)) [ \t]* \. [a-zA-Z_]\w* }x},
    {type => 'lbl', re => qr{ (?:^|(?<=\n)) [ \t]* [.\w\$]+ : }x},

    # AT&T mnemonics carry a size suffix (b/w/l/q/s)
    {
      type => 'kw',
      re   => qr{\b(?:
            mov[bwlqzx]? | add[bwlq]? | sub[bwlq]? | mul[bwlq]? | imul[bwlq]? |
            div[bwlq]? | idiv[bwlq]? | inc[bwlq]? | dec[bwlq]? | neg[bwlq]? |
            and[bwlq]? | or[bwlq]? | xor[bwlq]? | not[bwlq]? |
            shl[bwlq]? | shr[bwlq]? | sar[bwlq]? | rol[bwlq]? | ror[bwlq]? |
            cmp[bwlq]? | test[bwlq]? |
            push[bwlq]? | pop[bwlq]? |
            lea[bwlq]? | xchg[bwlq]? |
            jmp | j[a-z]+ | call[q]? | ret[q]? | leave[q]? | enter[q]? |
            int[3]? | hlt | nop | syscall | sysret |
            cld | std | cli | sti |
            rep | repe | repne | repz | repnz | lock |
            cmovs?[a-z]+
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            byte|word|long|quad|ascii|asciz|string|comm|lcomm|skip|zero|fill
        )\b}
    },
    {type => 'op', re => qr{[-+*/%=<>!&|^~?:]+}},
    {type => 'pn', re => qr{[(){}\[\],.]}},
    {type => 'id', re => qr{[A-Za-z_.][.\w]*}},
  ],
};

$LANG{fasm} = {
  name    => 'FASM',
  aliases => [qw(fasm flat-asm)],
  rules   => [
    {type => 'com', re => qr{;[^\n]*}},
    {type => 'str', re => $CSTR},
    {type => 'str', re => qr{ ' (?:[^'\\\n]|\\.)* ' }x},
    {type => 'num', re => qr{ \b 0[xX][0-9A-Fa-f]+ \b }x},
    {type => 'num', re => qr{ \b [0-9][0-9A-Fa-f]*[hH] \b }x},
    {type => 'num', re => qr{ \b 0[bB][01]+ \b }x},
    {type => 'num', re => qr{ \b \d+ \b }x},

    # FASM directives + structure macros
    {
      type => 'pre',
      re   => qr{\b(?:
            format|include|macro|purge|restore|fix|equ|=|
            org|use16|use32|use64|virtual|load|store|end|
            if|else|end\s+if|while|repeat|times|break|
            display|err|assert|public|extrn|section|segment|stack|heap
        )\b}xi
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            db|dw|dd|dp|df|dq|dt|
            rb|rw|rd|rp|rf|rq|rt|
            byte|word|dword|fword|pword|qword|tbyte|tword|dqword|xword|yword|zword|ptr|
            data|code|readable|writable|executable|shareable|notpageable|discardable|
            ELF|PE|MZ|COFF|MS|console|GUI|DLL|EFI|EFIBOOT|EFIRUNTIME|native|driver|
            entry|stdcall|cdecl|fastcall|invoke|cinvoke|proc|endp
        )\b}xi
    },
    {type => 'lbl', re => qr{ (?:^|(?<=\n)) [ \t]* [.\w\$]+ : }x},
    {type => 'reg', re => $X86_REGS_FULL},
    {type => 'kw',  re => $X86_INSTRS},
    {type => 'op',  re => qr{[-+*/%=<>!&|^~?:]+}},
    {type => 'pn',  re => qr{[(){}\[\],]}},
    {type => 'id',  re => qr{[.\w\$]+}},
  ],
};

# APL primitives live in U+2200..U+22FF (Misc Technical) and a few
# neighbours; extending the set means appending to the gly char class.

$LANG{apl} = {
  name    => 'APL',
  aliases => [qw(apl dyalog)],
  rules   => [
    {type => 'com', re => qr{⍝[^\n]*}},

    # APL strings: 'foo' with '' for embedded apostrophe
    {type => 'str', re => qr{ ' (?:[^']|'')* ' }x},

    # ¯-prefix high minus, optional decimal, E exponent, J complex.
    {
      type => 'num',
      re   => qr{
            ¯? (?: \d+ (?:\.\d+)? | \.\d+ )
            (?:[eE]¯?\d+)?
            (?:J ¯? (?:\d+(?:\.\d+)? | \.\d+) (?:[eE]¯?\d+)?)?
        }x
    },

    # System functions/variables (⎕FOO ⍞ ⎕IO ...)
    {type => 'sys', re => qr{ ⎕ [A-Za-z]* | ⍞ }x},

    # Dfn args / tradfn dyadic args. Single glyphs only.
    {type => 'kw', re => qr{ [⍺⍵⍶⍹∇∆⍙] }x},

    # Primitive function / operator glyphs (broad set; common Dyalog).
    {
      type => 'gly',
      re   => qr{ [
            \+\-\×÷\*⍟⌹○\!\?⌈⌊⊥⊤\|≤<=>≥≠≡≢
            ∊⍷∪∩~∨∧⍱⍲⍳⍴,⍪⌽⊖⍉⌷⊃⊂⊆⊇⊏⊐
            \↑\↓⍒⍋⌽⍕⍎⊣⊢⍝⍞←→
            /\\⌿⍀¨\.∘⍤⍥⍣⍨⍢⌸⌺⍠
        ] }x
    },
    {type => 'pn', re => qr{[(){}\[\];:◇⋄]}},
    {type => 'id', re => qr{[A-Za-z_∆⍙][\w∆⍙]*}},
  ],
};

$LANG{bash} = {
  name    => 'Bash',
  aliases => [qw(bash sh shell zsh)],
  rules   => [
    {type => 'com', re => qr{ \# [^\n]* }x},

    # Just the `<<EOF` / `<<-EOF` introducer; body untracked.
    {type => 'pre', re => qr{ <<-? \w+ }x},

    # $'...'  (ANSI-C escapes) and $"..."  (translatable strings)
    {type => 'str', re => qr{ \$ ' (?:[^'\\]|\\.)* ' }x},
    {type => 'str', re => qr{ \$ " (?:[^"\\]|\\.)* " }x},
    {type => 'str', re => qr{ " (?:[^"\\]|\\.)* " }sx},
    {type => 'str', re => qr{ ' [^']* ' }x},

    # Variable expansions: $foo, ${foo}, $1, $@, $#, $$, $!
    {type => 'reg', re => qr{ \$ \{ [^\}\n]* \} }x},
    {type => 'reg', re => qr{ \$ [A-Za-z_]\w* }x},
    {type => 'reg', re => qr{ \$ [0-9@*\#?!\$\-] }x},
    {type => 'pre', re => qr{ \$\( | \) | `[^`\n]*` }x},
    {type => 'num', re => qr{ \b 0[xX][0-9A-Fa-f]+ \b }x},
    {type => 'num', re => qr{ \b \d+ \b }x},
    {
      type => 'kw',
      re   => qr{\b(?:
            if|then|elif|else|fi|case|esac|while|until|do|done|for|in|
            select|function|return|local|declare|readonly|export|typeset|
            unset|break|continue|exit|trap|source|alias|let|time
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            echo|printf|read|cd|pwd|test|eval|exec|set|shift|getopts|
            true|false|:|sleep|wait|kill|jobs|fg|bg|umask|hash
        )\b}x
    },
    {type => 'attr', re => qr{(?:^|(?<=\s)) -{1,2} [\w-]+ }x},
    {type => 'op',   re => qr{(?:&&|\|\||<<-?|>>|<<<|;;|[|&;<>]) }x},
    {type => 'pn',   re => qr{[\(\)\{\}\[\]\$=,]}},
    {type => 'id',   re => qr{[A-Za-z_]\w*}},
  ],
};

$LANG{python} = {
  name    => 'Python',
  aliases => [qw(python py python3)],
  rules   => [
    {type => 'com', re => qr{ \# [^\n]* }x},

    # Most-greedy first, else single-quote strings eat the fence.
    {type => 'str',  re => qr{ [bBrRuUfF]{0,2} """ .*? """ }sx},
    {type => 'str',  re => qr{ [bBrRuUfF]{0,2} ''' .*? ''' }sx},
    {type => 'str',  re => qr{ [bBrRuUfF]{0,2} " (?:[^"\\\n]|\\.)* " }x},
    {type => 'str',  re => qr{ [bBrRuUfF]{0,2} ' (?:[^'\\\n]|\\.)* ' }x},
    {type => 'attr', re => qr{ \@ [A-Za-z_]\w* (?:\.[A-Za-z_]\w*)* }x},
    {
      type => 'num',
      re   =>
        qr{ \b (?:0[xX][0-9A-Fa-f_]+ | 0[oO][0-7_]+ | 0[bB][01_]+ | \d[\d_]* (?:\.\d[\d_]*)? (?:[eE][-+]?\d+)? ) [jJ]? \b }x
    },
    {
      type => 'kw',
      re   => qr{\b(?:
            False|None|True|and|as|assert|async|await|break|class|continue|
            def|del|elif|else|except|finally|for|from|global|if|import|in|
            is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|
            match|case
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            int|float|complex|bool|str|bytes|bytearray|memoryview|list|tuple|
            range|dict|set|frozenset|object|type|None|Ellipsis|NotImplemented
        )\b}x
    },
    {
      type => 'cst',
      re   => qr{\b(?:
            print|len|range|list|dict|set|tuple|str|int|float|bool|isinstance|
            zip|enumerate|map|filter|sorted|reversed|sum|min|max|abs|round|
            open|input|iter|next|hasattr|getattr|setattr|delattr|id|hash|
            repr|vars|dir|help|format|chr|ord|bin|hex|oct|all|any|callable|
            classmethod|staticmethod|property|super|__name__|__main__|self|cls
        )\b}x
    },
    {
      type => 'op',
      re   => qr{(?:->|\*\*=?|//=?|<<=?|>>=?|==|!=|<=|>=|:=|[-+*/%&|^~=<>!]) }x
    },
    {type => 'pn', re => qr{[\(\)\{\}\[\];,.:]}},
    {type => 'id', re => qr{[A-Za-z_]\w*}},
  ],
};

$LANG{javascript} = {
  name    => 'JavaScript',
  aliases => [qw(javascript js ecmascript es typescript ts)],
  rules   => [
    {type => 'com', re => $CCOMMENT_BLOCK},
    {type => 'com', re => $CCOMMENT_LINE},

    # Backtick template literal; interpolation isn't broken out.
    {type => 'str', re => qr{ ` (?:[^`\\]|\\.)* ` }sx},
    {type => 'str', re => qr{ " (?:[^"\\\n]|\\.)* " }x},
    {type => 'str', re => qr{ ' (?:[^'\\\n]|\\.)* ' }x},

    # Regex literal: /.../flags. Approximation - no contextual heuristics.
    {type => 'str', re => qr{ / (?:[^/\\\n]|\\.)+ / [gimsuy]* }x},
    {
      type => 'num',
      re   =>
        qr{ \b (?:0[xX][0-9A-Fa-f_]+ | 0[oO][0-7_]+ | 0[bB][01_]+ | \d[\d_]* (?:\.\d[\d_]*)? (?:[eE][-+]?\d+)? )n? \b }x
    },
    {
      type => 'kw',
      re   => qr{\b(?:
            var|let|const|function|class|extends|new|this|super|return|
            if|else|for|while|do|switch|case|default|break|continue|
            try|catch|finally|throw|typeof|instanceof|in|of|delete|void|
            null|undefined|true|false|async|await|yield|
            import|export|from|as|with|debugger|
            interface|type|enum|implements|public|private|protected|readonly|abstract
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:
            string|number|boolean|symbol|bigint|object|any|never|unknown|
            Array|Object|String|Number|Boolean|Promise|Map|Set|WeakMap|
            WeakSet|Symbol|Date|RegExp|Error|JSON|Math|console|window|document
        )\b}x
    },
    {type => 'cst', re => qr{\b(?:null|undefined|true|false|NaN|Infinity)\b}},
    {
      type => 'op',
      re   =>
        qr{(?:===|!==|=>|\.\.\.|<=|>=|==|!=|&&|\|\||\?\?|<<=?|>>>?=?|\*\*=?|[-+*/%=<>!&|^~?]) }x
    },
    {type => 'pn', re => qr{[\(\)\{\}\[\];,.:]}},
    {type => 'id', re => qr{[A-Za-z_\$][\w\$]*}},
  ],
};

$LANG{html} = {
  name    => 'HTML',
  aliases => [qw(html htm xml xhtml svg)],
  rules   => [
    {type => 'com', re => qr{ <!-- .*? --> }sx},
    {type => 'pre', re => qr{ <! [^>]+ > }x},      # <!DOCTYPE ...>
        # Tag with attributes: <name attr="val" ...>
    {type => 'kw',   re => qr{ </?  [A-Za-z][\w-]*    }x},    # <tag or </tag
    {type => 'pn',   re => qr{ /?>                  }x},
    {type => 'attr', re => qr{ \b [A-Za-z_-][\w:-]* (?= \s* = ) }x},
    {type => 'op',   re => qr{ = }x},
    {type => 'str',  re => qr{ " [^"]* "  }x},
    {type => 'str',  re => qr{ ' [^']* '  }x},
    {
      type => 'cst',
      re   => qr{ & (?: \# \d+ | \# x[0-9A-Fa-f]+ | [A-Za-z]+ ) ; }x
    },
    {type => 'id', re => qr{[A-Za-z_][\w-]*}},
  ],
};

$LANG{sql} = {
  name    => 'SQL',
  aliases => [qw(sql sqlite postgres postgresql mysql)],
  rules   => [
    {type => 'com', re => qr{ -- [^\n]* }x},
    {type => 'com', re => $CCOMMENT_BLOCK},
    {type => 'str', re => qr{ ' (?:[^']|'')* ' }x},
    {type => 'str', re => qr{ " (?:[^"]|"")* " }x},      # delimited identifier
    {type => 'num', re => qr{ \b \d+ (?:\.\d+)? \b }x},
    {
      type => 'kw',
      re   => qr{\b(?i:
            SELECT|FROM|WHERE|JOIN|INNER|LEFT|RIGHT|OUTER|FULL|CROSS|ON|USING|
            AS|AND|OR|NOT|IN|IS|NULL|LIKE|GLOB|REGEXP|BETWEEN|EXISTS|ANY|ALL|
            GROUP|BY|ORDER|HAVING|LIMIT|OFFSET|FETCH|FIRST|NEXT|ROWS|ONLY|
            INSERT|INTO|VALUES|UPDATE|SET|DELETE|RETURNING|UPSERT|REPLACE|
            CREATE|DROP|ALTER|TABLE|INDEX|VIEW|TRIGGER|SEQUENCE|SCHEMA|
            DATABASE|TEMPORARY|TEMP|IF|THEN|ELSE|CASE|WHEN|END|UNION|INTERSECT|
            EXCEPT|DISTINCT|WITH|RECURSIVE|BEGIN|COMMIT|ROLLBACK|TRANSACTION|
            SAVEPOINT|RELEASE|GRANT|REVOKE|PRIMARY|KEY|FOREIGN|REFERENCES|
            UNIQUE|CONSTRAINT|CHECK|DEFAULT|AUTO_INCREMENT|AUTOINCREMENT|
            COLLATE|CASCADE|RESTRICT|NO|ACTION|MATCH|EXPLAIN|ANALYZE|VACUUM
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?i:
            INT|INTEGER|SMALLINT|BIGINT|TINYINT|MEDIUMINT|DECIMAL|NUMERIC|
            FLOAT|REAL|DOUBLE|PRECISION|MONEY|CHAR|VARCHAR|NCHAR|NVARCHAR|
            TEXT|CLOB|DATE|TIME|TIMESTAMP|TIMESTAMPTZ|DATETIME|INTERVAL|
            BLOB|BYTEA|BOOLEAN|BOOL|UUID|JSON|JSONB|ARRAY|XML|GEOMETRY
        )\b}x
    },
    {
      type => 'cst',
      re   =>
        qr{\b(?i:NULL|TRUE|FALSE|CURRENT_DATE|CURRENT_TIME|CURRENT_TIMESTAMP)\b}
    },
    {type => 'op', re => qr{(?:<>|<=|>=|==|!=|\|\||[-+*/%=<>!]) }x},
    {type => 'pn', re => qr{[(),;.]}},
    {type => 'id', re => qr{[A-Za-z_]\w*}},
  ],
};

$LANG{lisp} = {
  name    => 'Lisp / Scheme',
  aliases => [qw(lisp scheme racket clojure cl elisp)],
  rules   => [
    {type => 'com', re => qr{ ; [^\n]* }x},
    {type => 'com', re => qr{ \#\| .*? \|\# }sx},
    {type => 'str', re => qr{ " (?:[^"\\]|\\.)* " }sx},
    {type => 'chr', re => qr{ \#\\ (?:space|newline|tab|return|\w|[^\s\)]) }x},

    # Boolean / quote / unquote / various reader macros
    {type => 'cst', re => qr{ \#[tf] }x},
    {type => 'cst', re => qr{ \#:\w+ }x},    # keyword (Racket / CL)
    {type => 'op',  re => qr{ ['\`,@] }x},
    {type => 'num', re => qr{ \b -? \d+ (?:\.\d+)? (?:e[-+]?\d+)? \b }x},

    # Special forms
    {
      type => 'kw',
      re   => qr{(?:^|(?<=[\s\(]))(?:
            define | defun | defmacro | defstruct | defclass | defmethod |
            defparameter | defvar | defconstant |
            let\* | let | letrec | flet | labels |
            lambda | function | quote | quasiquote | unquote | unquote-splicing |
            if | cond | case | when | unless | do | dolist | dotimes |
            loop | for | while |
            begin | progn | prog1 | prog2 |
            set! | setf | setq |
            and | or | not |
            require | provide | export | import | use-module |
            module | library | package | namespace
        )\b}x
    },

    # Common predicates / built-ins
    {
      type => 'typ',
      re   => qr{(?:^|(?<=[\s\(]))(?:
            null\? | eq\? | equal\? | eqv\? | pair\? | list\? | symbol\? |
            string\? | number\? | procedure\? | vector\? | port\? | char\? |
            cons | car | cdr | caar | cadr | cdar | cddr | list | length |
            map | for-each | filter | fold | foldl | foldr | reduce |
            apply | call/cc | call-with-current-continuation |
            display | write | read | newline | error
        )(?=[\s\(\)])}x
    },
    {type => 'pn', re => qr{[\(\)\[\]]}},
    {
      type => 'id',
      re   => qr{[A-Za-z_!\$%&*+\-./:<=>?@^~][\w!\$%&*+\-./:<=>?@^~]*}
    },
  ],
};

$LANG{perl} = {
  name    => 'Perl',
  aliases => [qw(perl pl pm)],
  rules   => [

    # POD =pod / =cut - colour the markers, leave body
    {type => 'com', re => qr{ ^=\w+ [^\n]* (?:\n(?!=cut).*?)? ^=cut }smx},
    {type => 'com', re => qr{ \# [^\n]* }x},
    {type => 'str', re => qr{ q[wqrx]? \{ [^\}]* \} }x},
    {type => 'str', re => qr{ q[wqrx]? \( [^\)]* \) }x},
    {type => 'str', re => qr{ q[wqrx]? \[ [^\]]* \] }x},
    {type => 'str', re => qr{ q[wqrx]? \< [^\>]* \> }x},
    {type => 'str', re => qr{ " (?:[^"\\]|\\.)* " }sx},
    {type => 'str', re => qr{ ' [^']* ' }x},
    {type => 'reg', re => qr{ [\$\@%&] \{? [A-Za-z_]\w* (?:::\w+)* \}? }x},
    {type => 'reg', re => qr{ \$ [0-9_!@\#\$\-] }x},
    {type => 'num', re => qr{ \b 0[xX][0-9A-Fa-f]+ \b }x},
    {type => 'num', re => qr{ \b \d+ (?:\.\d+)? (?:[eE][-+]?\d+)? \b }x},
    {
      type => 'kw',
      re   => qr{\b(?:
            my|our|local|state|sub|use|no|require|package|
            if|elsif|else|unless|while|until|for|foreach|do|last|next|redo|return|
            die|warn|eval|print|printf|say|chomp|chop|chr|ord|sprintf|
            split|join|map|grep|sort|reverse|keys|values|each|push|pop|shift|unshift|
            defined|exists|delete|wantarray|ref|bless|tie|untie|
            qw|qq|q|qr|m|s|tr|y
        )\b}x
    },
    {
      type => 'typ',
      re   => qr{\b(?:undef|true|false|STDIN|STDOUT|STDERR|ARGV|ENV)\b}
    },
    {
      type => 'op',
      re   =>
        qr{(?:=>|->|\.\.\.|\.\.|<=>|//=|//|cmp|eq|ne|lt|gt|le|ge|or|xor|and|not|<<|>>|\*\*|<=|>=|==|!=|=~|!~|&&|\|\||[-+*/%=<>!&|^~?]) }x
    },
    {type => 'pn', re => qr{[\(\)\{\}\[\];,.:]}},
    {type => 'id', re => qr{[A-Za-z_]\w*}},
  ],
};

$LANG{make} = {
  name    => 'Makefile',
  aliases => [qw(make makefile bsdmake gmake)],
  rules   => [
    {type => 'com', re => qr{ \# [^\n]* }x},
    {type => 'str', re => qr{ " (?:[^"\\]|\\.)* " }x},
    {type => 'str', re => qr{ ' [^']* ' }x},

    # Variable references: $(NAME), ${NAME}, $@, $<, $^, $*, $?
    {type => 'reg', re => qr{ \$ [\(\{] [^\)\}\n]* [\)\}] }x},
    {type => 'reg', re => qr{ \$ [\@<\^*?] }x},

    # Targets at column 0: `name:` or `name target:` (anything before colon).
    {
      type => 'lbl',
      re   => qr{ (?:^|(?<=\n)) [A-Za-z0-9_./%-][\w\s./%\-+]*? : (?!=) }x
    },
    {
      type => 'pre',
      re   => qr{(?:^|(?<=\n))[ \t]*[\.@-]?(?:
            include|sinclude|-include|
            ifeq|ifneq|ifdef|ifndef|else|endif|
            define|endef|export|unexport|override|
            \.PHONY|\.SUFFIXES|\.DEFAULT|\.PRECIOUS|\.INTERMEDIATE
        )\b}x
    },
    {
      type => 'kw',
      re   => qr{ \$ \( (?:
            subst|patsubst|foreach|wildcard|shell|dir|notdir|basename|
            suffix|addsuffix|addprefix|word|firstword|lastword|words|
            wordlist|filter|filter-out|sort|strip|origin|flavor|call|
            error|warning|info|abspath|realpath|file|value|eval
        ) \b }x
    },
    {type => 'op',  re => qr{(?: [:?+!]?=|\?=|\+=|::=) }x},
    {type => 'pn',  re => qr{[\(\)\{\};,]}},
    {type => 'num', re => qr{ \b \d+ \b }x},
    {type => 'id',  re => qr{[A-Za-z_./][\w./-]*}},
  ],
};

$LANG{dockerfile} = {
  name    => 'Dockerfile',
  aliases => [qw(dockerfile docker)],
  rules   => [
    {type => 'com', re => qr{ \# [^\n]* }x},
    {type => 'str', re => qr{ " (?:[^"\\]|\\.)* " }sx},
    {type => 'str', re => qr{ ' [^']* ' }x},
    {type => 'reg', re => qr{ \$ \{ [^\}\n]* \} }x},
    {type => 'reg', re => qr{ \$ [A-Za-z_]\w* }x},

    # Directives at start of line (uppercase per convention).
    {
      type => 'kw',
      re   => qr{(?:^|(?<=\n))[ \t]*(?:
            FROM|RUN|CMD|LABEL|MAINTAINER|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|
            VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL|
            from|run|cmd|label|maintainer|expose|env|add|copy|entrypoint|
            volume|user|workdir|arg|onbuild|stopsignal|healthcheck|shell
        )\b}x
    },
    {type => 'attr', re => qr{ -{1,2} [\w-]+ }x},
    {type => 'num',  re => qr{ \b \d+ \b }x},
    {type => 'op',   re => qr{[\\=]}},
    {type => 'pn',   re => qr{[\[\]\{\},:]}},
    {type => 'id',   re => qr{[A-Za-z_][\w./-]*}},
  ],
};

$LANG{diff} = {
  name    => 'Diff',
  aliases => [qw(diff patch udiff)],
  rules   => [
    {
      type => 'pre',
      re   => qr{(?:^|(?<=\n))(?:diff |index |--- |\+\+\+ ) [^\n]* }x
    },
    {type => 'kw',  re => qr{(?:^|(?<=\n))@@ [^\n]* @@ [^\n]* }x},
    {type => 'cst', re => qr{(?:^|(?<=\n))\+ [^\n]* }x},           # added line
    {type => 'com', re => qr{(?:^|(?<=\n))-  [^\n]* }x}
    ,    # removed (note 1 space)
    {type => 'com', re => qr{(?:^|(?<=\n))-[^\n]*}x},    # removed line
    {type => 'id',  re => qr{[^\n]+}x},                  # context
  ],
};

$LANG{json} = {
  name    => 'JSON',
  aliases => [qw(json jsonc json5)],
  rules   => [
    {type => 'com', re => $CCOMMENT_BLOCK},
    {type => 'com', re => $CCOMMENT_LINE},

    # Key: a string immediately followed by colon (look-ahead).
    {type => 'attr', re => qr{ " (?:[^"\\]|\\.)* " (?= \s* : ) }x},
    {type => 'str',  re => qr{ " (?:[^"\\]|\\.)* " }x},
    {type => 'num',  re => qr{ -? \b \d+ (?:\.\d+)? (?:[eE][-+]?\d+)? \b }x},
    {type => 'cst',  re => qr{\b(?:true|false|null)\b}},
    {type => 'pn',   re => qr{[\{\}\[\],:]}},
    {type => 'id',   re => qr{[A-Za-z_][\w-]*}},
  ],
};

$LANG{yaml} = {
  name    => 'YAML',
  aliases => [qw(yaml yml)],
  rules   => [
    {type => 'com', re => qr{ \# [^\n]* }x},

    # `--- ` document separator
    {type => 'pre', re => qr{(?:^|(?<=\n))---[ \t\r\n] }x},
    {type => 'pre', re => qr{(?:^|(?<=\n))\.\.\.\s*$}mx},
    {type => 'str', re => qr{ " (?:[^"\\]|\\.)* " }x},
    {type => 'str', re => qr{ ' (?:[^']|'')* ' }x},

    # Key: identifier followed by `:` (and space or EOL)
    {
      type => 'attr',
      re   => qr{ (?:^|(?<=\n))[ \t]* [A-Za-z_][\w.-]* (?= \s* : (?:\s|$)) }x
    },

    # Anchors and aliases
    {type => 'reg', re => qr{ [&*] [A-Za-z_][\w-]* }x},

    # Tags
    {type => 'pre', re => qr{ ! [\w!.\/-]* }x},
    {type => 'num', re => qr{ \b -? \d+ (?:\.\d+)? \b }x},
    {
      type => 'cst',
      re   =>
        qr{\b(?:true|false|null|yes|no|on|off|True|False|Null|Yes|No|On|Off|TRUE|FALSE|NULL|YES|NO|ON|OFF|~)\b}
    },
    {type => 'op', re => qr{[:>|]}},
    {type => 'pn', re => qr{[\{\}\[\],-]}},
    {type => 'id', re => qr{[A-Za-z_][\w-]*}},
  ],
};

$LANG{toml} = {
  name    => 'TOML',
  aliases => [qw(toml)],
  rules   => [
    {type => 'com', re => qr{ \# [^\n]* }x},

    # Section headers `[section]` or `[[array.section]]`
    {type => 'lbl', re => qr{ (?:^|(?<=\n)) \[ \[? [^\]\n]+ \]? \] }x},
    {type => 'str', re => qr{ """ .*? """ }sx},
    {type => 'str', re => qr{ ''' .*? ''' }sx},
    {type => 'str', re => qr{ " (?:[^"\\]|\\.)* " }x},
    {type => 'str', re => qr{ ' [^']* ' }x},

    # ISO-8601 date / datetime
    {
      type => 'num',
      re   =>
        qr{ \b \d{4}-\d{2}-\d{2} (?:[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[-+]\d{2}:?\d{2})?)? \b }x
    },
    {type => 'num', re => qr{ \b -? \d+ (?:\.\d+)? (?:[eE][-+]?\d+)? \b }x},
    {
      type => 'num',
      re   =>
        qr{ \b 0[xX][0-9A-Fa-f_]+ \b | \b 0[oO][0-7_]+ \b | \b 0[bB][01_]+ \b }x
    },
    {type => 'cst', re => qr{\b(?:true|false)\b}},

    # Bare-key followed by `=`
    {
      type => 'attr',
      re   => qr{ (?:^|(?<=\n))[ \t]* [A-Za-z0-9_-]+ (?= \s* = ) }x
    },
    {type => 'op', re => qr{=}},
    {type => 'pn', re => qr{[\{\}\[\],.]}},
    {type => 'id', re => qr{[A-Za-z_][\w-]*}},
  ],
};

$LANG{markdown} = {
  name    => 'Markdown',
  aliases => [qw(markdown md)],
  rules   => [
    {type => 'kw',   re => qr{(?:^|(?<=\n))\#{1,6}[ \t][^\n]*}x},
    {type => 'lbl',  re => qr{(?:^|(?<=\n))> [^\n]*}x},
    {type => 'pre',  re => qr{(?:^|(?<=\n))(?:    |\t)[^\n]*}x},
    {type => 'pre',  re => qr{```[\s\S]*?```}x},
    {type => 'str',  re => qr{ ` [^`\n]+ ` }x},
    {type => 'cst',  re => qr{ \*\* [^\*\n]+ \*\* }x},
    {type => 'cst',  re => qr{ __ [^_\n]+ __ }x},
    {type => 'attr', re => qr{ \* [^\*\n]+ \* }x},
    {type => 'attr', re => qr{ _  [^_\n]+ _ }x},
    {type => 'com',  re => qr{ ~~ [^~\n]+ ~~ }x},
    {type => 'reg',  re => qr{!\[[^\]]*\]\([^)]*\)}x},
    {type => 'op',   re => qr{\[[^\]]+\]\([^)]*\)}x},
    {type => 'num',  re => qr{(?:^|(?<=\n))[ \t]*(?:[-*+]|\d+\.)[ \t]}x},
    {type => 'pn',   re => qr{(?:^|(?<=\n))[-*_]{3,}[ \t]*$}mx},
    {type => 'id',   re => qr{[^\n`*_~\[\!#>]+}x},
  ],
};

$LANG{plain} = {
  name    => 'plain',
  aliases => [qw(plain text txt none plaintext)],
  rules   => [],
};

# Build alias -> canonical-name map.
for my $name (keys %LANG) {
  $ALIAS{$name} = $name;
  $ALIAS{$_}    = $name for @{$LANG{$name}{aliases} || []};
}

sub known {
  my ($lang) = @_;
  return 0 unless defined $lang && length $lang;
  my $k = lc $lang;
  return 1 if exists $ALIAS{$k};
  _refresh_db_langs();
  return exists $DB_ALIAS{$k} ? 1 : 0;
}

sub languages {
  _refresh_db_langs();
  my %seen = map {$_ => 1} keys %LANG;
  $seen{$_} = 1 for keys %DB_LANG;
  return sort keys %seen;
}

sub highlight {
  my ($code, $lang) = @_;
  $code = '' unless defined $code;
  my $key   = defined $lang && length $lang ? lc $lang : 'plain';
  my $canon = $ALIAS{$key};
  my $def;
  if ($canon) {
    $def = $LANG{$canon};
  }
  else {
    _refresh_db_langs();
    my $dc = $DB_ALIAS{$key};
    if ($dc) {
      $canon = $dc;
      $def   = $DB_LANG{$dc};
    }
  }
  $def //= $LANG{plain};

  my $tokens = _tokenize($code, $def->{rules});
  my $body   = '';
  for my $t (@$tokens) {
    my $text = escape_html($t->{text});
    if ($t->{type} eq 'plain') {
      $body .= $text;
    }
    else {
      $body .= qq{<span class="hl-$t->{type}">$text</span>};
    }
  }

  my $cls = 'hl';
  $cls .= ' lang-' . _ident($canon) if $canon;

  # Class on the <pre> so block-level CSS (overflow, padding, max-width)
  # targets the actual frame around the code.
  return qq{<pre class="$cls"><code>$body</code></pre>};
}

use constant MAX_HIGHLIGHT_BYTES => 256 * 1024;

sub _tokenize {
  my ($text, $rules) = @_;
  return [{type => 'plain', text => $text}] if !@$rules || !length $text;
  return [{type => 'plain', text => $text}]
    if length $text > MAX_HIGHLIGHT_BYTES;

  # One combined regex with a named capture per rule replaces the
  # per-position rule loop (was O(rules * text^2) on no-match runs).
  # Leftmost match wins; per-rule order disambiguates ties.
  my $combined = _combined_for($rules);
  my @types    = map {$_->{type}} @$rules;

  my @out;
  while ($text =~ /\G(.*?)$combined/gcs) {
    my $plain = $1;
    push @out, {type => 'plain', text => $plain} if length $plain;
    for my $i (0 .. $#types) {
      my $g = "t$i";
      next unless defined $+{$g};
      push @out, {type => $types[$i], text => $+{$g}};
      last;
    }
  }
  my $left = pos($text) // 0;
  push @out, {type => 'plain', text => substr($text, $left)}
    if $left < length $text;
  return \@out;
}

# Combine a rules list into one alternation with named per-rule
# captures. Memoized on the rules array reference so each $LANG entry
# pays exactly once per process.
sub _combined_for {
  my ($rules) = @_;
  my $key = "$rules";       # array-ref stringified address; stable per process
  return $_COMBINED{$key} if $_COMBINED{$key};
  my @parts;
  for my $i (0 .. $#$rules) {

    # (?:...) wrapper isolates each rule's internals; named outer
    # group lets us read which alternative fired via %+.
    push @parts, "(?<t$i>(?:$rules->[$i]{re}))";
  }
  my $alt = join '|', @parts;
  return $_COMBINED{$key} = qr/$alt/s;
}

sub _ident {
  my $s = shift // '';
  $s =~ s/[^A-Za-z0-9_-]/-/g;
  return $s;
}

1;
