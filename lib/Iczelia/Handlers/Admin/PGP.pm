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

package Iczelia::Handlers::Admin::PGP;
use strict;
use warnings;
use Iczelia::HTTP                   ();
use Iczelia::Handlers::Admin::Forms qw(simple_form_render_html);

use constant PGP_BODY_MAX => 256 * 1024;

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->{auth}->route_gate($ctx);
  $router->get('/admin/pgp/',         $gate->(\&_pgp_form));
  $router->post('/admin/pgp/',        $gate->(\&_pgp_upload));
  $router->post('/admin/pgp/delete',  $gate->(\&_pgp_delete));
}

sub _pgp_path {
  my ($ctx) = @_;
  require Iczelia::Handlers::Static;
  return Iczelia::Handlers::Static::_var_dir_of($ctx->{cfg}) . '/pub.pgp';
}

sub _pgp_form {
  my ($ctx, $req) = @_;
  my $sid   = $req->{auth_sid};
  my $path  = _pgp_path($ctx);
  my $size  = -e $path ? (-s $path)      : 0;
  my $mtime = -e $path ? (stat $path)[9] : 0;

  my @bits;
  push @bits,
    '<p>The key uploaded here is served at <code>/pub.pgp</code> with content-type <code>application/pgp-keys</code>.</p>';
  if ($size) {
    push @bits, sprintf '<p>Currently installed: %d bytes, uploaded %s.</p>',
      $size, Iczelia::Handlers::Admin::ts_fmt($mtime);
  }
  else {
    push @bits,
      '<p>No key installed. <code>/pub.pgp</code> currently 404s.</p>';
  }
  push @bits, '<p><label>Upload a new key (.pgp / .asc / armored text)<br>'
    . '<input type="file" name="file" accept=".pgp,.asc,application/pgp-keys,text/plain" required></label></p>';

  my $body =
    '<form class="cms-form" method="POST" action="/admin/pgp/" enctype="multipart/form-data">'
    . '<input type="hidden" name="csrf" value="'
    . $ctx->{auth}->csrf_token($sid, 'pgp') . '">'
    . join('', @bits)
    . '<p class="cms-actions"><button type="submit" class="cms-btn cms-btn-primary">upload</button></p>'
    . '</form>';
  if ($size) {
    $body .=
      '<form class="cms-form" method="POST" action="/admin/pgp/delete" onsubmit="return confirm(\'remove the installed PGP key?\')">'
      . '<input type="hidden" name="csrf" value="'
      . $ctx->{auth}->csrf_token($sid, 'pgp:delete') . '">'
      . '<p class="cms-actions"><button type="submit" class="cms-btn cms-btn-danger">remove key</button></p>'
      . '</form>';
  }

  return Iczelia::HTTP::html(
    simple_form_render_html(
      $ctx, $req,
      title => 'pgp public key',
      body  => $body,
    )
  );
}

sub _pgp_upload {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'pgp');
  return $err if $err;

  my @files = @{$req->{uploads} || []};
  return Iczelia::HTTP::error(400, 'no file') unless @files;
  my $f = $files[0];

  return Iczelia::HTTP::error(413, 'too large') if $f->{size} > PGP_BODY_MAX;

  # Accept ASCII-armoured text or any >= 8-byte binary blob; we don't
  # do cryptographic validation, just refuse zero-byte files.
  my $body = $f->{body} // '';
  return Iczelia::HTTP::error(400, 'empty') unless length $body >= 8;

  my $path = _pgp_path($ctx);
  my $dir  = $path;
  $dir =~ s{[^/]+\z}{};
  if ($dir && !-d $dir) {
    require File::Path;
    File::Path::make_path($dir);
  }
  my $tmp = "$path.tmp.$$";
  open my $fh, '>:raw', $tmp or return Iczelia::HTTP::error(500, "write: $!");
  print $fh $body;
  close $fh;
  rename $tmp, $path or do {
    unlink $tmp;
    return Iczelia::HTTP::error(500, "rename: $!");
  };
  return Iczelia::HTTP::redirect('/admin/pgp/');
}

sub _pgp_delete {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'pgp:delete');
  return $err if $err;
  my $path = _pgp_path($ctx);
  unlink $path if -e $path;
  return Iczelia::HTTP::redirect('/admin/pgp/');
}

1;
