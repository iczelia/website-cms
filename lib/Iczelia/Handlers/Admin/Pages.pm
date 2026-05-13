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

package Iczelia::Handlers::Admin::Pages;
use strict;
use warnings;
use Iczelia::HTTP                   ();
use Iczelia::Time                   qw(ts_fmt);
use Iczelia::Handlers::Admin::Forms qw(field_for_form);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->{auth}->route_gate($ctx);
  $router->get('/admin/edit/:slug',  $gate->(\&_edit_page));
  $router->post('/admin/edit/:slug', $gate->(\&_save_page));
}

sub _edit_page {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $page = $ctx->{content}->get_page($slug)
    or return Iczelia::HTTP::error(404, 'no such page');

  my $sch = eval {$ctx->{schema}->load($page->{template})}
    or return Iczelia::HTTP::error(500,
    "no schema for template '$page->{template}'");

  my $data = $ctx->{schema}->decode($page->{data});
  my $sid  = $req->{auth_sid};
  my $csrf = $ctx->{auth}->csrf_token($sid, "page:$slug");

  my @fields;
  for my $f (@{$sch->{fields}}) {
    push @fields, field_for_form($f, $data->{$f->{name}});
  }

  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_edit_page.tpl',
    title     => "edit $slug",
    csrf_form => $csrf,
    page      => {
      slug        => $slug,
      template    => $page->{template},
      updated_fmt => ts_fmt($page->{updated_at}),
    },
    fields => \@fields,
  );
}

sub _save_page {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $page = $ctx->{content}->get_page($slug)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->{auth}->require_csrf($req, "page:$slug");
  return $err if $err;

  my ($data, $errs) =
    $ctx->{schema}->parse_form($page->{template}, $req->{params});
  my $json = $ctx->{schema}->encode($data);
  $ctx->{content}->save_page($slug, $page->{title}, $page->{template}, $json);
  return Iczelia::HTTP::redirect('/admin/');
}

1;
