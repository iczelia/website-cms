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
use Iczelia::Markup                 ();
use Iczelia::Highlight              ();

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
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
  my $kv  = $ctx->content->all_settings;
  my $sid = $req->{auth_sid};

  my @groups;
  for my $g (@SETTINGS_GROUPS) {
    my ($id, $label, $keys) = @$g;
    my @fields;
    for my $k (@$keys) {
      (my $display = $k) =~ s/^\Q$id\E\.//;
      push @fields,
        {
        key     => $k,
        display => $display,
        value   => $kv->{$k} // '',
        };
    }
    push @groups, {id => $id, label => $label, fields => \@fields};
  }

  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_settings.tpl',
    title       => 'settings',
    form_action => '/admin/settings/',
    form_csrf   => $ctx->auth->csrf_token($sid, 'settings'),
    groups      => \@groups,
  );
}

sub _settings_save {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'settings');
  return $err if $err;
  my $allowed = _settings_keys();
  my %kv;
  for my $k (keys %{$req->{params}}) {
    $kv{$k} = $req->{params}{$k} if $allowed->{$k};
  }
  $ctx->content->set_settings(\%kv);
  return Iczelia::HTTP::redirect('/admin/settings/');
}

# Exercises every hl-* class plus realistic snippets, so theme.code.*
# tweaks have one canonical preview surface.
my @THEME_PREVIEW_CLASSES =
  qw(com str chr num kw typ cst pre op pn id attr lt mac reg lbl gly sys);
my @THEME_PREVIEW_SAMPLES = (
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

sub _theme_preview {
  my ($ctx, $req) = @_;
  my @samples =
    map +{lang => $_->[0], html => Iczelia::Highlight::highlight($_->[1], $_->[0])},
    @THEME_PREVIEW_SAMPLES;
  my $vars = $ctx->render->base_vars(
    title   => 'iczelia :: theme preview',
    page    => {is_admin_preview => 1},
    classes => [@THEME_PREVIEW_CLASSES],
    samples => \@samples,
    blockquote_sample_html =>
      Iczelia::Highlight::highlight(q{int x = 1; /* in a quote */}, 'c'),
  );
  return Iczelia::HTTP::html(
    $ctx->template->render('views/theme_preview.tpl', $vars));
}

# Preview shares one per-session token across every admin form, so we
# verify the token but skip the form_name binding.
sub _preview {
  my ($ctx, $req) = @_;
  my $tok      = $req->{params}{csrf} // '';
  my $expected = $ctx->auth->csrf_token($req->{auth_sid}, 'preview');
  return Iczelia::HTTP::error(400, 'csrf')
    unless $tok eq $expected;
  my $body = $req->{params}{body} // '';
  my ($html, $math) = Iczelia::Markup::render($body);
  if (my $tex = $ctx->render->tex) {
    $html =~ s{__MATH(\d+)__}{
            my $m = $math->[$1];
            $m ? $tex->render(@$m) : ''
        }ge;
  }
  return Iczelia::HTTP::html($html);
}

1;
