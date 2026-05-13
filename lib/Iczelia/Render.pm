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

package Iczelia::Render;
use strict;
use warnings;
use Carp            qw(croak);
use Iczelia::Util   qw(escape_html escape_attr clamp_int clamp_flt decode_json_hash);
use Iczelia::Time   qw(fmt_date fmt_ago atom_iso clock_string);
use Iczelia::Markup ();
use Iczelia::Minify ();

use constant SETTINGS_CACHE_TTL => 60;

# DB rows -> markdown -> math substitution -> template render,
# caching the final HTML back to the row's rendered_html column.

my %KAPPA_LABEL = (
  "\x{03c6}" => 'philosophy',
  "\x{03c0}" => 'science',
  "\x{03bb}" => 'code',
  "\x{03b4}" => 'release',
  "\x{03c9}" => 'opinion',
  "\x{03bc}" => 'meta',
);

sub _kappa_title {
  my ($kappa) = @_;
  return '' unless defined $kappa && length $kappa;
  my @parts;
  for my $g (split /\s+/, $kappa) {
    push @parts, "$g $KAPPA_LABEL{$g}" if $KAPPA_LABEL{$g};
  }
  return join(' / ', @parts);
}

sub new {
  my ($class, %arg) = @_;
  croak "db required"       unless $arg{db};
  croak "template required" unless $arg{template};
  my $self = bless {
    db       => $arg{db},
    template => $arg{template},
    tex      => $arg{tex},        # optional Iczelia::Tex
    cache    => $arg{cache},      # optional Iczelia::Cache
    cfg      => $arg{cfg},
  }, $class;
  return $self;
}

sub base_vars {
  my ($self, %extra) = @_;
  my $now = time;
  if (!$self->{_settings_cache}
    || $now - ($self->{_settings_at} // 0) >= SETTINGS_CACHE_TTL)
  {
    my $rows = $self->{db}->all('SELECT key, value FROM settings');
    my %s;
    for my $r (@$rows) {
      my ($k, $v) = ($r->{key}, $r->{value});
      my @parts = split /\./, $k, 2;
      if   (@parts == 2) {$s{$parts[0]}{$parts[1]} = $v}
      else               {$s{$k}                   = $v}
    }
    $self->{_settings_cache} = \%s;
    $self->{_settings_at}    = $now;
    delete $self->{_theme_css_cache};
  }

  # Shallow-copy the top level so per-call %extra additions don't
  # leak back into the cache.
  my %s      = %{$self->{_settings_cache}};
  my $author = $s{site}{author} // '';

  # Synthesise "(c) START - YEAR HOLDER" when the operator didn't.
  my $now_year = (gmtime)[5] + 1900;
  my $copy     = $s{site}{copyright};
  unless (defined $copy && length $copy) {
    my $start  = $s{site}{copyright_start}  // 2019;
    my $holder = $s{site}{copyright_holder} // ($author || 'iczelia');
    $copy = "(c) $start - $now_year $holder";
  }

  # short = "(c) <years>", author = holder. Lets the chrome drop
  # the holder at narrow breakpoints.
  my $copy_short  = $copy;
  my $copy_author = $s{site}{copyright_holder} // $author;
  $copy_short =~ s/\s*\(c\)/(c)/;
  if ($copy_short =~ s/^(.*\d{4})\s+(\S.*)$/$1/) {
    $copy_author = $2 unless defined $s{site}{copyright_holder};
  }

  my $email      = $s{site}{email} // '';
  my $email_html = _obfuscate_email($email);

  my $theme_css = $self->{_theme_css_cache} //= _theme_css(\%s);
  my %math      = _math_params(\%s);
  my %figure    = _figure_params(\%s);

  # SEO/social <head> metadata. Callers pass `meta => {...}` to
  # override the website-wide defaults (canonical URL, description,
  # keywords, og:type, article timestamps, robots, ...). Relative
  # paths in canonical/image are resolved against site.base_url.
  my $base_url = $s{site}{base_url} // '';
  $base_url =~ s{/+$}{};
  my %meta = (
    description    => $s{site}{description} // $s{site}{tagline} // '',
    keywords       => $s{site}{keywords}    // '',
    canonical      => '',
    og_type        => 'website',
    og_title       => '',
    published_time => '',
    modified_time  => '',
    robots         => '',
  );
  if (ref $extra{meta} eq 'HASH') {
    my $o = delete $extra{meta};
    %meta = (%meta, %$o);
  }

  # og:image: explicit override, else first body image, else site card,
  # else logo. Made absolute below. (posts use `post`, pages use `data`.)
  unless (length($meta{image} // '')) {
    my $post = ref $extra{post} eq 'HASH' ? $extra{post} : {};
    my $data = ref $extra{data} eq 'HASH' ? $extra{data} : {};
    $meta{image} =
         _first_content_img($post->{body_html})
      || _first_content_img($data->{body_html})
      || _first_content_img($data->{intro_html})
      || $s{site}{og_image}
      || '/assets-1024x768/iczelia-128.png';
  }

  for my $k (qw(canonical image)) {
    next unless defined $meta{$k} && $meta{$k} =~ m{^/};
    $meta{$k} = "$base_url$meta{$k}" if length $base_url;
  }
  $meta{og_url} = $meta{canonical} unless defined $meta{og_url};
  $meta{og_locale} = $s{site}{og_locale} // 'en_US'
    unless defined $meta{og_locale};

  # og:title: an explicit override, else the page <title> with the
  # "<site> :: " prefix dropped so it doesn't echo og:site_name.
  my $site_title = $s{site}{title} // 'iczelia';
  my $og_title   = $meta{og_title};
  $og_title = $extra{title} if !defined $og_title || !length $og_title;
  $og_title = $site_title   if !defined $og_title || !length $og_title;
  $og_title =~ s/^\Q$site_title\E\s*::\s*//;
  $meta{og_title} = length $og_title ? $og_title : $site_title;

  return {
    site => {
      base_url         => $base_url,
      copyright        => $copy,
      copyright_short  => $copy_short,
      copyright_author => $copy_author,
      email            => $email,
      email_html       => $email_html,
      tagline          => $s{site}{tagline} // '',
      author           => $author,
      title            => $s{site}{title} // 'iczelia',
    },
    social => {
      github   => $s{github}   || {},
      mastodon => $s{mastodon} || {},
      bluesky  => $s{bluesky}  || {},
    },
    chrome => {
      theme_css => $theme_css,
      figure    => \%figure,
      math      => \%math,
    },
    meta => \%meta,
    page => {},
    %extra,
  };
}

# first content <img> src, for og:image; skips rendered-LaTeX PNGs
sub _first_content_img {
  my ($html) = @_;
  return '' unless defined $html && length $html;
  while ($html =~ /<img\b([^>]*)>/gi) {
    my $attrs = $1;
    next if $attrs =~ /\bclass\s*=\s*["'][^"']*\bmath\b/i;
    if ($attrs =~ /\bsrc\s*=\s*["']([^"']+)["']/i) {
      my $src = $1;
      $src =~ s/&amp;/&/g;
      return $src;
    }
  }
  return '';
}

# Decoy spans (.no-spam / .fake, aria-hidden) feed naive scrapers
# garbage; sighted readers see the real address.
sub _obfuscate_email {
  my ($e) = @_;
  return '' unless defined $e && $e =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/;
  my ($user, $domain) = split /\@/, $e, 2;
  my @dom_parts = split /\./, $domain;
  return Iczelia::Util::escape_html($e) if @dom_parts < 2;
  my $tld  = pop @dom_parts;
  my $rest = join('.', @dom_parts);
  my $u    = Iczelia::Util::escape_html($user);
  my $r    = Iczelia::Util::escape_html($rest);
  my $t    = Iczelia::Util::escape_html($tld);
  return
      $u
    . '<span class="np" aria-hidden="true">.no-spam</span>@'
    . $r
    . '<span class="np" aria-hidden="true">.fake</span>.'
    . $t;
}

# Inline theme overrides; emits only declarations that differ from
# the static defaults so an untouched install ships nothing.
my %DEFAULT_HL = (
  bg     => '#060912',
  border => '#2a3548',
  text   => '#b9c8d6',
  com    => '#5a7a98',
  str    => '#d8b97e',
  num    => '#c89dd6',
  kw     => '#6ea4d6',
  typ    => '#b8e0f4',
  cst    => '#c89dd6',
  pre    => '#d8a87c',
  attr   => '#d8a87c',
  lt     => '#b8e0f4',
  mac    => '#d8b97e',
  reg    => '#b8e0f4',
  lbl    => '#ffffff',
  gly    => '#6ea4d6',
  sys    => '#d8a87c',
  op     => '#cfdde9',
  pn     => '#6e8aa8',
  id     => '#b9c8d6',
);

sub _theme_css {
  my ($s) = @_;

  # base_vars splits at the first dot only, so `theme.code.kw`
  # lands in $s->{theme}{'code.kw'}; re-flatten here.
  my %hl;
  if (ref $s->{theme} eq 'HASH') {
    for my $k (keys %{$s->{theme}}) {
      if ($k =~ /^code\.(.+)$/) {$hl{$1} = $s->{theme}{$k}}
    }
  }
  my $hl = \%hl;
  my @rules;
  if ( _diff($hl->{bg}, $DEFAULT_HL{bg})
    || _diff($hl->{border}, $DEFAULT_HL{border})
    || _diff($hl->{text},   $DEFAULT_HL{text}))
  {
    my $bg = _ok_color($hl->{bg})     // $DEFAULT_HL{bg};
    my $bd = _ok_color($hl->{border}) // $DEFAULT_HL{border};
    my $tx = _ok_color($hl->{text})   // $DEFAULT_HL{text};
    push @rules, ".hl{background:$bg;border-color:$bd;color:$tx}";
  }
  for my $t (
    sort grep {$_ ne 'bg' && $_ ne 'border' && $_ ne 'text'}
    keys %DEFAULT_HL
    )
  {
    next unless _diff($hl->{$t}, $DEFAULT_HL{$t});
    my $c = _ok_color($hl->{$t}) or next;
    push @rules, ".hl-${t}\{color:$c\}";
  }
  my $fig = $s->{figure} || {};
  if (defined $fig->{bg} || defined $fig->{border}) {
    my @decls;
    if (my $b = _ok_color($fig->{bg}))     {push @decls, "background:$b"}
    if (my $b = _ok_color($fig->{border})) {push @decls, "border-color:$b"}
    push @rules, ".ab-section figure{" . join(';', @decls) . "}" if @decls;
  }
  return @rules ? join('', @rules) : '';
}

sub _diff {
  my ($a, $b) = @_;
  return 0 unless defined $a && length $a;
  return lc $a ne lc($b // '');
}

sub _ok_color {
  my ($c) = @_;
  return undef unless defined $c && length $c;
  return $c if $c =~ /\A#[0-9A-Fa-f]{3,8}\z/;
  return $c if $c =~ /\A(?:rgba?|hsla?)\([0-9.,\s%\/]+\)\z/i;
  return undef;
}

sub _math_params {
  my ($s) = @_;
  my $m = $s->{math} || {};
  return (
    dpi          => clamp_int($m->{dpi},         120, 60, 240),
    inline_pt    => clamp_int($m->{inline_pt},   10,  6,  18),
    display_pt   => clamp_int($m->{display_pt},  11,  6,  20),
    glow_radius  => clamp_int($m->{glow_radius}, 2,   0,  8),
    glow_opacity => clamp_flt($m->{glow_opacity}, 0.55, 0, 1),
  );
}

sub _figure_params {
  my ($s) = @_;
  my $f = $s->{figure} || {};
  return (
    bg     => _ok_color($f->{bg})     // '',
    border => _ok_color($f->{border}) // '#2a3548',
  );
}


require Iczelia::Render::Markup;
require Iczelia::Render::Invalidate;
require Iczelia::Render::Assets;
require Iczelia::Render::Page;

1;
