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

package Iczelia::Handlers::Admin::Settings;
use strict;
use warnings;
use Iczelia::HTTP                   ();
use Iczelia::Util                   qw(escape_attr);
use Iczelia::Markup                 ();
use Iczelia::Highlight              ();
use Iczelia::Handlers::Admin::Forms qw(simple_form_render);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = sub {
    my $fn = shift;
    sub {$ctx->{auth}->gate($fn, $ctx, $_[0])}
  };
  $router->get('/admin/settings/',                $gate->(\&_settings_form));
  $router->post('/admin/settings/',               $gate->(\&_settings_save));
  $router->get('/admin/settings/theme-preview',   $gate->(\&_theme_preview));
  $router->post('/admin/preview',                 $gate->(\&_preview));
}

# Single source of truth for editable settings: drives both the form
# layout and the save-time allowlist.
my @SETTINGS_GROUPS = (
  [
    'site', 'site',
    [
      qw(site.title site.tagline site.description site.keywords
        site.og_image site.author site.email site.base_url
        site.copyright site.copyright_start site.copyright_holder)
    ]
  ],
  [
    'social', 'social',
    [
      qw(github.username github.url
        mastodon.handle mastodon.url mastodon.feed_url
        bluesky.handle bluesky.url)
    ]
  ],
  ['fetcher', 'activity fetcher', [qw(fetcher.timeout_s fetcher.user_agent)]],
  [
    'math', 'math (TeX rendering)',
    [
      qw(math.dpi math.inline_pt math.display_pt
        math.glow_radius math.glow_opacity)
    ]
  ],
  ['figure', 'figure', [qw(figure.bg figure.border)]],
  [
    'theme', 'theme - code colours',
    [
      qw(theme.code.bg theme.code.border theme.code.text
        theme.code.com theme.code.str theme.code.num
        theme.code.kw  theme.code.typ theme.code.cst
        theme.code.pre theme.code.attr theme.code.lt
        theme.code.mac theme.code.reg theme.code.lbl
        theme.code.gly theme.code.sys theme.code.op
        theme.code.pn  theme.code.id)
    ]
  ],
);

sub _settings_keys {
  my %seen;
  for my $g (@SETTINGS_GROUPS) {$seen{$_} = 1 for @{$g->[2]}}
  return \%seen;
}

sub _settings_form {
  my ($ctx, $req) = @_;
  my $kv  = $ctx->{content}->all_settings;
  my $sid = $req->{auth_sid};

  my @bits;
  for my $g (@SETTINGS_GROUPS) {
    my ($id, $label, $keys) = @$g;
    push @bits,
      qq{<fieldset class="cms-settings-group cms-settings-group-$id"><legend>$label</legend><table class="cms-settings"><tbody>};
    for my $k (@$keys) {
      my $v = escape_attr($kv->{$k} // '');
      (my $display = $k) =~ s/^\Q$id\E\.//;
      push @bits,
        qq{<tr><td><label for="s_$k">$display</label></td><td><input id="s_$k" type="text" name="$k" value="$v"></td></tr>};
    }
    push @bits, qq{</tbody></table></fieldset>};
  }
  push @bits,
    qq{<p class="cms-help"><a href="/admin/settings/theme-preview" target="_blank" rel="noopener">preview the current code theme &raquo;</a></p>};

  return Iczelia::HTTP::html(
    simple_form_render(
      $ctx, $req,
      title  => 'settings',
      action => '/admin/settings/',
      csrf   => $ctx->{auth}->csrf_token($sid, 'settings'),
      body   => join('', @bits),
    )
  );
}

sub _settings_save {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'settings');
  return $err if $err;
  my $allowed = _settings_keys();
  my %kv;
  for my $k (keys %{$req->{params}}) {
    $kv{$k} = $req->{params}{$k} if $allowed->{$k};
  }
  $ctx->{content}->set_settings(\%kv);
  return Iczelia::HTTP::redirect('/admin/settings/');
}

# Exercises every hl-* class plus realistic snippets, so theme.code.*
# tweaks have one canonical preview surface.
sub _theme_preview {
  my ($ctx, $req) = @_;
  my @cls =
    qw(com str chr num kw typ cst pre op pn id attr lt mac reg lbl gly sys);
  my @samples = (
    [
      'c', q{int main(void) {
    /* hello */
    char *s = "world";
    if (s == NULL) return 0;
    return printf("hi %s\n", s);
}}
    ],
    [
      'python', q{# fibonacci
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a}
    ],
    [
      'bash', q{#!/bin/sh
set -eu
for f in *.txt; do
    grep -i "TODO" "$f" || true
done}
    ],
    [
      'perl', q{use strict;
my @primes = grep { !($_ % 2) } 2..50;
print join(',', @primes), "\n";}
    ],
  );
  my @bits;
  push @bits, qq{<h2>token classes</h2>};
  push @bits,
    qq{<table class="cms-table"><thead><tr><th>class</th><th>swatch</th></tr></thead><tbody>};
  for my $c (@cls) {
    push @bits,
      qq{<tr><td><code>hl-$c</code></td><td><pre class="hl"><code><span class="hl-$c">sample text $c</span></code></pre></td></tr>};
  }
  push @bits, qq{</tbody></table>};
  push @bits, qq{<h2>code samples</h2>};
  for my $s (@samples) {
    my ($lang, $code) = @$s;
    my $hl = Iczelia::Highlight::highlight($code, $lang);
    push @bits, qq{<h3>$lang</h3>};
    push @bits, $hl;
  }
  push @bits, qq{<h2>inside a blockquote</h2>};
  push @bits,
    qq{<blockquote><p>quoted text with <code>inline code</code> in the middle &mdash; the inline-code rule is italic by default; check it doesn't fight the box.</p>};
  push @bits,
    Iczelia::Highlight::highlight(q{int x = 1; /* in a quote */}, 'c');
  push @bits, qq{</blockquote>};

  my $vars = $ctx->{render}->base_vars(
    title     => 'iczelia :: theme preview',
    page      => {is_admin_preview => 1},
    body_html => join('', @bits),
  );

  # Inherit the public page layout so the theme CSS actually applies.
  return Iczelia::HTTP::html(
    $ctx->{template}->render('views/theme_preview.tpl', $vars));
}

# Preview shares one per-session token across every admin form, so we
# verify the token but skip the form_name binding.
sub _preview {
  my ($ctx, $req) = @_;
  my $tok      = $req->{params}{csrf} // '';
  my $expected = $ctx->{auth}->csrf_token($req->{auth_sid}, 'preview');
  return Iczelia::HTTP::error(400, 'csrf')
    unless $tok eq $expected;
  my $body = $req->{params}{body} // '';
  my ($html, $math) = Iczelia::Markup::render($body);
  if ($ctx->{render}->{tex}) {
    $html =~ s{__MATH(\d+)__}{
            my $m = $math->[$1];
            $m ? $ctx->{render}->{tex}->render(@$m) : ''
        }ge;
  }
  return Iczelia::HTTP::html($html);
}

1;
