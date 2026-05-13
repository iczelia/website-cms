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

package Iczelia::Handlers::Admin::Highlight;
use strict;
use warnings;
use Iczelia::HTTP      ();
use Iczelia::Highlight ();

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = sub {
    my $fn = shift;
    sub {$ctx->{auth}->gate($fn, $ctx, $_[0])}
  };
  $router->get('/admin/highlight/',           $gate->(\&_lang_list));
  $router->get('/admin/highlight/new',        $gate->(\&_lang_new));
  $router->post('/admin/highlight/new',       $gate->(\&_lang_create));
  $router->get('/admin/highlight/:id/edit',   $gate->(\&_lang_edit));
  $router->post('/admin/highlight/:id/edit',  $gate->(\&_lang_update));
  $router->post('/admin/highlight/:id/delete',$gate->(\&_lang_delete));
}

sub _lang_list {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{content}->list_langs;
  my $sid  = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{updated_fmt} = Iczelia::Handlers::Admin::ts_fmt($r->{updated_at});
    $r->{csrf_del}    = $ctx->{auth}->csrf_token($sid, "lang:del:$r->{id}");
  }
  my @builtins = Iczelia::Highlight::languages();
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_highlight_list.tpl',
      Iczelia::Handlers::Admin::admin_vars(
        $ctx, $req,
        title        => 'highlighter languages',
        langs        => $rows,
        builtins_str => join(', ', @builtins),
      )
    )
  );
}

sub _render_lang_form {
  my ($ctx, $req, $row, %opt) = @_;
  my $sid       = $req->{auth_sid};
  my $form_name = $row ? "lang:$row->{id}" : 'lang:new';
  my $action =
    $row
    ? "/admin/highlight/$row->{id}/edit"
    : '/admin/highlight/new';
  my $rec = $opt{params}
    || (
    $row
    ? {
      name          => $row->{name},
      aliases       => $row->{aliases},
      keywords      => $row->{keywords},
      types         => $row->{types},
      builtins      => $row->{builtins},
      line_comment  => $row->{line_comment},
      block_comment => $row->{block_comment},
      string_quotes => $row->{string_quotes},
    }
    : {
      name          => '',
      aliases       => '',
      keywords      => '',
      types         => '',
      builtins      => '',
      line_comment  => '',
      block_comment => '',
      string_quotes => '"',
    }
    );
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_highlight_edit.tpl',
      Iczelia::Handlers::Admin::admin_vars(
        $ctx, $req,
        title       => $row ? "edit $row->{name}" : 'new language',
        row         => $row,
        form_action => $action,
        csrf_form   => $ctx->{auth}->csrf_token($sid, $form_name),
        error       => $opt{error},
        rec         => $rec,
      )
    )
  );
}

sub _lang_new {
  my ($ctx, $req) = @_;
  return _render_lang_form($ctx, $req, undef);
}

sub _lang_edit {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $row = $ctx->{content}->get_lang($id)
    or return Iczelia::HTTP::error(404);
  return _render_lang_form($ctx, $req, $row);
}

sub _lang_create {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'lang:new');
  return $err if $err;
  my ($id, $why) = $ctx->{content}->create_lang($req->{params});
  if (!$id) {
    return _render_lang_form(
      $ctx, $req, undef,
      error  => $why,
      params => $req->{params}
    );
  }
  return Iczelia::HTTP::redirect("/admin/highlight/$id/edit");
}

sub _lang_update {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "lang:$id");
  return $err if $err;
  my $cur = $ctx->{content}->get_lang($id)
    or return Iczelia::HTTP::error(404);
  my ($_id, $why) = $ctx->{content}->update_lang($id, $req->{params});
  if ($why) {
    return _render_lang_form(
      $ctx, $req, $cur,
      error  => $why,
      params => $req->{params}
    );
  }
  return Iczelia::HTTP::redirect("/admin/highlight/$id/edit");
}

sub _lang_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "lang:del:$id");
  return $err if $err;
  $ctx->{content}->delete_lang($id);
  return Iczelia::HTTP::redirect('/admin/highlight/');
}

1;
