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

package Iczelia::Handlers::Admin::Dynamic;
use strict;
use warnings;
use Iczelia::HTTP                   ();
use Iczelia::Time                   qw(ts_fmt);
use Iczelia::Handlers::Admin::Forms qw(field_for_form);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->{auth}->route_gate($ctx);
  $router->get('/admin/dynamic/',            $gate->(\&_dynamic_list));
  $router->get('/admin/dynamic/new',         $gate->(\&_dynamic_new));
  $router->post('/admin/dynamic/new',        $gate->(\&_dynamic_create));
  $router->get('/admin/dynamic/:id/edit',    $gate->(\&_dynamic_edit));
  $router->post('/admin/dynamic/:id/edit',   $gate->(\&_dynamic_update));
  $router->post('/admin/dynamic/:id/delete', $gate->(\&_dynamic_delete));
}

sub _dynamic_list {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{content}->list_dynamic_pages;
  my $sid  = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{updated_fmt} = ts_fmt($r->{updated_at});
    $r->{csrf_del}    = $ctx->{auth}->csrf_token($sid, "dynpage:del:$r->{id}");
  }
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_dynamic_list.tpl',
      Iczelia::Handlers::Admin::admin_vars(
        $ctx, $req,
        title => 'dynamic pages',
        pages => $rows,
      )
    )
  );
}

# Add an entry here for each <name>.tpl + <name>.json pair under
# share/templates that the admin form should expose.
sub _dynamic_template_options {
  return [{name => 'generic', label => 'generic (markdown body)'},];
}

sub _render_dynamic_form {
  my ($ctx, $req, $row, %opt) = @_;
  my $sid       = $req->{auth_sid};
  my $form_name = $row ? "dynpage:$row->{id}" : 'dynpage:new';
  my $action =
    $row
    ? "/admin/dynamic/$row->{id}/edit"
    : '/admin/dynamic/new';
  my $tpl_opts    = _dynamic_template_options();
  my $current_tpl = $row ? $row->{template} : ($opt{template} || 'generic');

  my $schema = $ctx->{schema}->load($current_tpl);
  my $data   = $row ? $ctx->{schema}->decode($row->{data}) : {};

  # On a re-display after a validation error, prefer the user's
  # in-flight params over the persisted row.
  if ($opt{params}) {
    my ($parsed) = $ctx->{schema}->parse_form($current_tpl, $opt{params});
    $data = $parsed if $parsed;
  }

  my @field_html;
  for my $f (@{$schema->{fields}}) {
    push @field_html, field_for_form($f, $data->{$f->{name}});
  }

  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_dynamic_edit.tpl',
      Iczelia::Handlers::Admin::admin_vars(
        $ctx, $req,
        title         => $row ? "edit $row->{route}" : 'new dynamic page',
        row           => $row,
        form_action   => $action,
        csrf_form     => $ctx->{auth}->csrf_token($sid, $form_name),
        template_opts => $tpl_opts,
        current_tpl   => $current_tpl,
        schema        => $schema,
        fields_html   => \@field_html,
        error         => $opt{error},
        route_value   => ($opt{params}{route} // ($row ? $row->{route} : '/')),
        title_value   => ($opt{params}{title} // ($row ? $row->{title} : '')),
      )
    )
  );
}

sub _dynamic_new {
  my ($ctx, $req) = @_;
  return _render_dynamic_form($ctx, $req, undef);
}

sub _dynamic_edit {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $row = $ctx->{content}->get_dynamic_page($id)
    or return Iczelia::HTTP::error(404);
  return _render_dynamic_form($ctx, $req, $row);
}

sub _dynamic_create {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'dynpage:new');
  return $err if $err;
  my $tpl = $req->{params}{template} || 'generic';
  my ($data, $errs) = $ctx->{schema}->parse_form($tpl, $req->{params});
  my $data_json = $ctx->{schema}->encode($data);
  my ($id, $why) = $ctx->{content}->create_dynamic_page(
    {
      route    => $req->{params}{route},
      title    => $req->{params}{title},
      template => $tpl,
      data     => $data_json,
    }
  );
  if (!$id) {
    return _render_dynamic_form(
      $ctx, $req, undef,
      error    => $why,
      params   => $req->{params},
      template => $tpl
    );
  }
  return Iczelia::HTTP::redirect("/admin/dynamic/$id/edit");
}

sub _dynamic_update {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "dynpage:$id");
  return $err if $err;
  my $cur = $ctx->{content}->get_dynamic_page($id)
    or return Iczelia::HTTP::error(404);
  my $tpl = $req->{params}{template} || $cur->{template};
  my ($data, $errs) = $ctx->{schema}->parse_form($tpl, $req->{params});
  my $data_json = $ctx->{schema}->encode($data);
  my ($_id, $why) = $ctx->{content}->update_dynamic_page(
    $id,
    {
      route    => $req->{params}{route},
      title    => $req->{params}{title},
      template => $tpl,
      data     => $data_json,
    }
  );

  if ($why) {
    return _render_dynamic_form(
      $ctx, $req, $cur,
      error    => $why,
      params   => $req->{params},
      template => $tpl
    );
  }
  return Iczelia::HTTP::redirect("/admin/dynamic/$id/edit");
}

sub _dynamic_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "dynpage:del:$id");
  return $err if $err;
  $ctx->{content}->delete_dynamic_page($id);
  return Iczelia::HTTP::redirect('/admin/dynamic/');
}

1;
