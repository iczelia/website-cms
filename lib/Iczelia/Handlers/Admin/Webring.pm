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

package Iczelia::Handlers::Admin::Webring;
use strict;
use warnings;
use Iczelia::HTTP                   ();
use Iczelia::Handlers::Admin::Forms qw(
  kvtable_html kvtable_rows_from_params simple_form_render
);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->{auth}->route_gate($ctx);
  $router->get('/admin/webring/',  $gate->(\&_webring_form));
  $router->post('/admin/webring/', $gate->(\&_webring_save));
}

sub _webring_form {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{content}->list_webring;
  my $sid  = $req->{auth_sid};

  my $field = {
    name    => 'rows',
    kind    => 'kv-table',
    label   => 'webring members',
    columns => [
      {name => 'section', label => 'section', kind => 'text', width => '15%'},
      {name => 'name',    label => 'name',    kind => 'text', width => '20%'},
      {name => 'url',     label => 'url',     kind => 'text', width => '35%'},
      {
        name  => 'image_url',
        label => '88x31 img',
        kind  => 'text',
        width => '30%'
      },
    ],
  };
  my @data = map {
    {
      section   => $_->{section} // 'others',
      name      => $_->{name},
      url       => $_->{url}       // '',
      image_url => $_->{image_url} // '',
    }
  } @$rows;
  my $html_inputs = kvtable_html($field, \@data);

  my $html = simple_form_render(
    $ctx, $req,
    title  => 'webring',
    action => '/admin/webring/',
    csrf   => $ctx->{auth}->csrf_token($sid, 'webring'),
    body   => $html_inputs,
  );
  return Iczelia::HTTP::html($html);
}

sub _webring_save {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'webring');
  return $err if $err;
  my @rows =
    grep {length($_->{name} // '')} kvtable_rows_from_params($req->{params});
  $ctx->{content}->replace_webring(\@rows);
  return Iczelia::HTTP::redirect('/admin/webring/');
}

1;
