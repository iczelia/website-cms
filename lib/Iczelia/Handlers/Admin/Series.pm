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

package Iczelia::Handlers::Admin::Series;
use strict;
use warnings;
use Iczelia::HTTP ();
use Iczelia::Time qw(ts_fmt);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  $router->get('/admin/series/',             $gate->(\&_series_list));
  $router->get('/admin/series/new',          $gate->(\&_series_new));
  $router->post('/admin/series/new',         $gate->(\&_series_create));
  $router->get('/admin/series/:id/edit',     $gate->(\&_series_edit));
  $router->post('/admin/series/:id/edit',    $gate->(\&_series_update));
  $router->post('/admin/series/:id/delete',  $gate->(\&_series_delete));
}

sub _series_list {
  my ($ctx, $req) = @_;
  my $rows = $ctx->content->list_series;
  my $sid  = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{updated_fmt} = ts_fmt($r->{updated_at});
    $r->{csrf_del}    = $ctx->auth->csrf_token($sid, "series:del:$r->{id}");
  }
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_series_list.tpl',
    title => 'series',
    rows  => $rows,
  );
}

sub _render_series_form {
  my ($ctx, $req, $row, %opt) = @_;
  my $sid       = $req->{auth_sid};
  my $form_name = $row ? "series:$row->{id}" : 'series:new';
  my $action =
      $row
    ? "/admin/series/$row->{id}/edit"
    : '/admin/series/new';
  my $rec = $opt{params}
    || (
    $row
    ? {
      slug        => $row->{slug},
      title       => $row->{title},
      description => $row->{description},
    }
    : {slug => '', title => '', description => ''}
    );
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_series_edit.tpl',
    title       => $row ? "edit series: $row->{title}" : 'new series',
    row         => $row,
    form_action => $action,
    csrf_form   => $ctx->auth->csrf_token($sid, $form_name),
    error       => $opt{error},
    rec         => $rec,
  );
}

sub _series_new  {my ($ctx, $req) = @_; _render_series_form($ctx, $req, undef)}

sub _series_edit {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $row = $ctx->content->get_series($id)
    or return Iczelia::HTTP::error(404);
  return _render_series_form($ctx, $req, $row);
}

sub _series_create {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'series:new');
  return $err if $err;
  my ($id, $why) = $ctx->content->create_series($req->{params});
  if (!$id) {
    return _render_series_form(
      $ctx, $req, undef,
      error  => $why,
      params => $req->{params}
    );
  }
  return Iczelia::HTTP::redirect("/admin/series/$id/edit");
}

sub _series_update {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->auth->require_csrf($req, "series:$id");
  return $err if $err;
  my $cur = $ctx->content->get_series($id)
    or return Iczelia::HTTP::error(404);
  my ($_id, $why) = $ctx->content->update_series($id, $req->{params});
  if ($why) {
    return _render_series_form(
      $ctx, $req, $cur,
      error  => $why,
      params => $req->{params}
    );
  }
  return Iczelia::HTTP::redirect("/admin/series/$id/edit");
}

sub _series_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->auth->require_csrf($req, "series:del:$id");
  return $err if $err;
  $ctx->content->delete_series($id);
  return Iczelia::HTTP::redirect('/admin/series/');
}

1;
