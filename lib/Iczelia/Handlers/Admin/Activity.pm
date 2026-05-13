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

package Iczelia::Handlers::Admin::Activity;
use strict;
use warnings;
use Iczelia::HTTP                   ();
use Iczelia::Handlers::Admin::Forms qw(
  kvtable_html kvtable_rows_from_params simple_form_render
);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  $router->get('/admin/updates/',           $gate->(\&_updates_form));
  $router->post('/admin/updates/',          $gate->(\&_updates_save));
  $router->get('/admin/activity/',          $gate->(\&_activity_view));
  $router->post('/admin/activity/currently',$gate->(\&_activity_currently));
  $router->post('/admin/activity/refresh',  $gate->(\&_activity_refresh));
}

sub _updates_form {
  my ($ctx, $req) = @_;
  my $rows = $ctx->content->list_updates;
  my $sid  = $req->{auth_sid};

  my $field = {
    name    => 'rows',
    kind    => 'kv-table',
    label   => 'updates',
    columns => [
      {name => 'date', label => 'date', kind => 'text', width => '20%'},
      {
        name  => 'body',
        label => 'body',
        kind  => 'markdown_inline',
        width => '80%'
      },
    ],
  };
  my @data        = map {{date => $_->{date}, body => $_->{body}}} @$rows;
  my $html_inputs = kvtable_html($field, \@data);

  my $html = simple_form_render(
    $ctx, $req,
    title  => 'updates',
    action => '/admin/updates/',
    csrf   => $ctx->auth->csrf_token($sid, 'updates'),
    body   => $html_inputs,
  );
  return Iczelia::HTTP::html($html);
}

sub _updates_save {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'updates');
  return $err if $err;
  my @rows = grep {
    ($_->{date} // '') =~ /^\d{4}-\d{2}-\d{2}$/
      && length($_->{body} // '')
  } kvtable_rows_from_params($req->{params});
  $ctx->content->replace_updates(\@rows);
  return Iczelia::HTTP::redirect('/admin/updates/');
}

sub _activity_view {
  my ($ctx, $req) = @_;
  my $rows = $ctx->content->list_activity;
  my %by_src;
  for my $r (@$rows) {push @{$by_src{$r->{source}}}, $r}
  my $currently =
    ($by_src{currently} && @{$by_src{currently}})
    ? $by_src{currently}[0]{text}
    : '';

  my $sid = $req->{auth_sid};
  my @sections;
  for my $s (qw(github mastodon bluesky)) {
    push @sections,
      {
      source => $s,
      rows   => $by_src{$s} || [],
      };
  }
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_activity.tpl',
    title      => 'activity',
    sections   => \@sections,
    currently  => $currently,
    csrf_extra => {
      currently => $ctx->auth->csrf_token($sid, 'activity:currently'),
      refresh   => $ctx->auth->csrf_token($sid, 'activity:refresh'),
    },
  );
}

sub _activity_currently {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'activity:currently');
  return $err if $err;
  $ctx->content->set_currently($req->{params}{currently} // '');
  return Iczelia::HTTP::redirect('/admin/activity/');
}

sub _activity_refresh {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'activity:refresh');
  return $err if $err;
  if ($ctx->fetcher) {
    eval {$ctx->fetcher->run_all};
  }
  return Iczelia::HTTP::redirect('/admin/activity/');
}

1;
