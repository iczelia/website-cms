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

package Iczelia::Tex;
use strict;
use warnings;
use Carp          qw(croak);
use Digest::SHA   qw(sha256_hex);
use Encode        ();
use File::Temp    ();
use MIME::Base64  ();
use POSIX         ();
use Time::HiRes   ();
use Iczelia::Util qw(escape_html escape_attr);

# Render LaTeX math to vector SVG embedded as a data: URL. The cache
# hash folds in render settings so an admin tweak invalidates cleanly.

use constant {
  DEFAULT_TIMEOUT => 5,
  MAX_INPUT       => 16 * 1024,
  MAX_OUTPUT      => 512 * 1024,
  DPI             => 120,

  # Cap how long a worker may serve stale math.* settings after an
  # admin save, vs. hitting the settings table per cache_key call.
  SETTINGS_TTL => 60,

  # Bump on preamble changes so cached failures auto-invalidate.
  PREAMBLE_VERSION => 2,
};

sub new {
  my ($class, %arg) = @_;
  croak "db required"      unless $arg{db};
  croak "tmp_dir required" unless $arg{tmp_dir};
  my $self = bless {
    db       => $arg{db},
    tmp_dir  => $arg{tmp_dir},
    timeout  => $arg{timeout}  || DEFAULT_TIMEOUT,
    latex    => $arg{latex}    || 'latex',
    dvisvgm  => $arg{dvisvgm}  || 'dvisvgm',
    gc_age   => $arg{gc_age}   || 30 * 86400,        # 30 days
    gc_every => $arg{gc_every} || 500,               # every Nth render
    renders  => 0,
  }, $class;
  -d $self->{tmp_dir} or croak "tmp_dir not a dir: $self->{tmp_dir}";
  return $self;
}

sub gc {
  my ($self, %opt) = @_;
  my $age = $opt{age} // $self->{gc_age};
  my $cut = time - $age;
  eval {
    $self->{db}->do_('DELETE FROM tex_cache WHERE created_at < ?', $cut);
    1;
  } or warn "tex_cache gc: $@";
}

sub _settings {
  my ($self) = @_;
  my $now = time;
  if ( $self->{_settings_cache}
    && $now - ($self->{_settings_at} // 0) < SETTINGS_TTL)
  {
    return $self->{_settings_cache};
  }
  my $rows = $self->{db}
    ->all(q{SELECT key, value FROM settings WHERE key LIKE 'math.%'});
  my %s;
  for my $r (@$rows) {
    my $k = $r->{key};
    $k =~ s/^math\.//;
    $s{$k} = $r->{value};
  }
  my $cfg = {
    dpi        => _clamp_int($s{dpi},        DPI, 60, 240),
    inline_pt  => _clamp_int($s{inline_pt},  10,  6,  18),
    display_pt => _clamp_int($s{display_pt}, 11,  6,  20),

    # Unused by the SVG pipeline; kept in cache_key so legacy
    # rows invalidate when an admin changes them.
    glow_radius  => _clamp_int($s{glow_radius}, 0, 0, 8),
    glow_opacity => _clamp_flt($s{glow_opacity}, 0, 0, 1),
    supersample  => _clamp_int($s{supersample}, 1, 1, 4),
  };
  $self->{_settings_cache} = $cfg;
  $self->{_settings_at}    = $now;
  return $cfg;
}

sub _clamp_int {
  my ($v, $def, $min, $max) = @_;
  return $def unless defined $v && $v =~ /\A-?\d+\z/;
  return $v < $min ? $min : ($v > $max ? $max : $v + 0);
}

sub _clamp_flt {
  my ($v, $def, $min, $max) = @_;
  return $def unless defined $v && $v =~ /\A-?\d+(?:\.\d+)?\z/;
  return $v < $min ? $min : ($v > $max ? $max : $v + 0);
}

# article{} only ships 10/11/12pt; extarticle covers the rest.
sub _docclass_for_pt {
  my ($pt) = @_;
  return ('article',    "${pt}pt") if $pt == 10 || $pt == 11 || $pt == 12;
  return ('extarticle', "${pt}pt");
}

sub cache_key {
  my ($self, $display, $tex) = @_;
  $display = $display ? 1 : 0;
  my $cfg = $self->_settings;

  # Each setting prefixed with its key=value form so two configs
  # like (dpi=12, inline=0) and (dpi=1, inline=20) can't collide.
  # PREAMBLE_VERSION participates so preamble changes auto-invalidate.
  my $key =
    ($display ? 'Dv5' : 'Iv5') . '|preamble=' . PREAMBLE_VERSION . '|' . join(
    '|',
    map {"$_=" . $cfg->{$_}}
      qw(dpi inline_pt display_pt
      glow_radius glow_opacity
      supersample)
    )
    . "\0"
    . ($tex // '');
  return sha256_hex(Encode::encode_utf8($key));
}

sub render {
  my ($self, $display, $tex) = @_;
  $display = $display ? 1 : 0;
  $tex //= '';
  return _err_span("empty math") unless length $tex;
  return _err_span("math too long") if length($tex) > MAX_INPUT;

  my $cfg  = $self->_settings;
  my $hash = $self->cache_key($display, $tex);
  if (my $row =
    $self->{db}->row('SELECT html FROM tex_cache WHERE hash=?', $hash))
  {
    return $row->{html};
  }

  my ($html, $err) = $self->_compile($display, $tex, $cfg);
  if (defined $err) {
    $html = _err_span($err, $tex);
  }

  # Cache failures too: otherwise a broken fragment loops forever
  # through the warmer. Fixing the source/settings changes the hash.
  eval {
    $self->{db}->do_(
      q{INSERT OR IGNORE INTO tex_cache(hash, display, html, created_at)
              VALUES(?,?,?,strftime('%s','now'))},
      $hash, $display, $html
    );
    1;
  } or warn "tex_cache insert: $@";

  return $html if defined $err;

  if (++$self->{renders} >= $self->{gc_every}) {
    $self->{renders} = 0;
    $self->gc;
  }

  return $html;
}

sub _compile {
  my ($self, $display, $tex, $cfg) = @_;
  $cfg ||= $self->_settings;

  my $scratch = File::Temp->newdir(
    TEMPLATE => 'tex-XXXXXX',
    DIR      => $self->{tmp_dir},
    CLEANUP  => 1,
  );

  my $fname = "$scratch/frag";

  my $math = $display ? "\\\[$tex\\\]"     : "\$$tex\$";
  my $pt   = $display ? $cfg->{display_pt} : $cfg->{inline_pt};
  my ($docclass, $clsopt) = _docclass_for_pt($pt);

  # Preamble: xcolor for \color, \lt/\gt for KaTeX-style sources,
  # Unicode minus/en/em-dash mapped to `-` so copy-paste doesn't break.
  my $body = <<"END_TEX";
\\documentclass[$clsopt]{$docclass}
\\usepackage[active,tightpage]{preview}
\\usepackage{amsmath,amssymb,amsthm}
\\usepackage{xcolor}
\\definecolor{transparent}{rgb}{1,1,1}
\\usepackage[utf8]{inputenc}
\\DeclareUnicodeCharacter{2212}{-}
\\DeclareUnicodeCharacter{2013}{-}
\\DeclareUnicodeCharacter{2014}{-}
\\providecommand{\\lt}{<}
\\providecommand{\\gt}{>}
\\begin{document}
\\begin{preview}
$math
\\end{preview}
\\end{document}
END_TEX

  open my $fh, '>:raw', "$fname.tex" or return (undef, "open frag.tex: $!");
  print $fh Encode::encode_utf8($body);
  close $fh;

  local $ENV{openin_any}  = 'p';
  local $ENV{openout_any} = 'p';
  local $ENV{TEXMFOUTPUT} = $scratch;
  local $ENV{TEXINPUTS}   = '.:';

  my ($rc, $log) =
    $self->_run_capped($self->{latex}, '-no-shell-escape',
    '-interaction=nonstopmode', '-halt-on-error', "-output-directory=$scratch",
    "$fname.tex",);
  if ($rc != 0) {
    return (undef, "latex failed (rc=$rc):\n" . _log_tail($log, 40));
  }
  return (undef, "no dvi produced") unless -s "$fname.dvi";

  my ($rc2, $info) = $self->_run_capped(
    $self->{dvisvgm},
    '--no-fonts',    # text -> <path>, no font dependency
    '--bbox=min',    # tight crop around ink (display math
                     # doesn't fill the LaTeX line width)
    '--exact-bbox',
    '--precision=4',
    '--optimize=all',
    "--output=$fname.svg",
    "$fname.dvi",
  );
  if ($rc2 != 0 || !-s "$fname.svg") {
    return (undef, "dvisvgm failed (rc=$rc2): " . _log_tail($info // '', 6));
  }

  open my $sf, '<:raw', "$fname.svg" or return (undef, "open svg: $!");
  local $/;
  my $svg = <$sf>;
  close $sf;
  if (length $svg > MAX_OUTPUT) {
    return (undef, "svg too large (" . length($svg) . " bytes)");
  }

  my ($svg_out, $w_px, $h_px, $depth_px) = _wrap_svg($svg, $cfg, $display);
  return (undef, "svg parse failed") unless defined $svg_out;

  my $b64 = MIME::Base64::encode_base64($svg_out, '');
  my $alt = escape_attr($tex);
  my $cls = $display ? 'math math-display' : 'math math-inline';

  my $img;
  if ($display) {
    $img = sprintf
      q{<img class="%s" alt="%s" title="%s" width="%d" height="%d" src="data:image/svg+xml;base64,%s">},
      $cls, $alt, $alt, $w_px, $h_px, $b64;
  }
  else {
    $img = sprintf
      q{<img class="%s" alt="%s" title="%s" width="%d" height="%d" src="data:image/svg+xml;base64,%s" style="vertical-align:-%dpx">},
      $cls, $alt, $alt, $w_px, $h_px, $b64, $depth_px;
  }
  return ($img, undef);
}

# Returns ($svg, $w_px, $h_px, $depth_px) - dimensions in CSS pixels.
sub _wrap_svg {
  my ($svg, $cfg, $display) = @_;
  return (undef) unless defined $svg && $svg =~ /<svg\b/;

  my ($attrs) = $svg =~ /<svg\b([^>]*)>/s;
  return (undef) unless defined $attrs;

  my ($vb) = $attrs =~ /\bviewBox\s*=\s*['"]([^'"]+)['"]/;
  return (undef) unless defined $vb;
  my @vb = split /\s+|,/, $vb;
  return (undef) unless @vb >= 4;
  my (undef, $vy, $vw, $vh) = @vb;

  # 1pt -> dpi/72 px to match the legacy dvipng visual size.
  my $dpi       = $cfg->{dpi} // DPI;
  my $px_per_pt = $dpi / 72;
  my $w_px      = int($vw * $px_per_pt + 0.5);
  my $h_px      = int($vh * $px_per_pt + 0.5);
  my $depth_pt  = $vy + $vh;
  $depth_pt = 0 if $depth_pt < 0;
  my $depth_px = int($depth_pt * $px_per_pt + 0.5);

  # --no-fonts paths render unfilled (black) under SVG defaults;
  # the white stroke also thickens Computer Modern's thin strokes.
  $svg =~ s{(<svg\b[^>]*>)}
             {$1\n<g fill="#ffffff" stroke="#ffffff" stroke-width="0.18">}s;
  $svg =~ s{</svg>}{</g></svg>}s;

  return ($svg, $w_px, $h_px, $depth_px);
}

# Run with stdin closed, capping wallclock and combined stdout/stderr.
sub _run_capped {
  my ($self, @cmd) = @_;

  my ($rd, $wr);
  pipe($rd, $wr) or return (-1, "pipe: $!");
  my $pid = fork();
  return (-1, "fork: $!") unless defined $pid;
  if ($pid == 0) {
    close $rd;
    open STDIN,  '<',  '/dev/null';
    open STDOUT, '>&', $wr;
    open STDERR, '>&', $wr;
    exec {$cmd[0]} @cmd;
    exit 127;
  }
  close $wr;

  my $buf      = '';
  my $deadline = time + $self->{timeout};
  my $killed   = 0;

  while (1) {
    my $rin = '';
    vec($rin, fileno($rd), 1) = 1;
    my $remaining = $deadline - time;
    last if $remaining <= 0;
    my $nfound = select(my $rout = $rin, undef, undef, $remaining);
    last if $nfound == 0;
    my $chunk;
    my $n = sysread($rd, $chunk, 65536);
    last if !defined $n || $n == 0;
    $buf .= $chunk;

    if (length($buf) > MAX_OUTPUT * 4) {
      $killed = 1;
      kill 'KILL', $pid;
      last;
    }
  }
  if (time >= $deadline && !$killed) {
    $killed = 1;
    kill 'TERM', $pid;

    # 200ms grace via short non-blocking poll, then SIGKILL.
    for (1 .. 10) {
      last if waitpid($pid, POSIX::WNOHANG()) > 0;
      Time::HiRes::sleep(0.02);
    }
    kill 'KILL', $pid;
  }

  close $rd;
  waitpid $pid, 0;
  my $rc = $?;
  return ($killed ? -1 : ($rc >> 8), $buf);
}

sub _log_tail {
  my ($s, $n) = @_;
  return '' unless defined $s;
  my @lines = split /\n/, $s;
  my $start = @lines > $n ? @lines - $n : 0;
  return join("\n", @lines[$start .. $#lines]);
}

sub _err_span {
  my ($why, $tex) = @_;
  my $literal = defined $tex ? escape_html($tex) : '';
  my $msg     = escape_html($why);
  return qq{<span class="tex-error" title="$msg"><code>$literal</code></span>};
}

1;
