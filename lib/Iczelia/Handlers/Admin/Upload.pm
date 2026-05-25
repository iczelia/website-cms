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

package Iczelia::Handlers::Admin::Upload;
use strict;
use warnings;
use JSON::PP        ();
use Iczelia::HTTP   ();
use Iczelia::Upload ();

# Chunked upload endpoints used by the admin JS uploader. The body
# size cap on the daemon (request-cap) and on nginx
# (client_max_body_size) sit well above MAX_CHUNK, so each chunk POST
# stays comfortably inside both. A consuming handler (backup import,
# subpages create/rezip, ...) reads the assembled file via
# Iczelia::Upload::claim.
#
# Routes:
#   POST /admin/upload/init                       -> {id}
#   POST /admin/upload/chunk?id=X&offset=N&csrf=T -> {size} (raw body)
#   POST /admin/upload/abort?id=X&csrf=T          -> {ok}

my $JSON = JSON::PP->new->utf8(1)->canonical(1);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  $router->post('/admin/upload/init',  $gate->(\&_init));
  $router->post('/admin/upload/chunk', $gate->(\&_chunk));
  $router->post('/admin/upload/abort', $gate->(\&_abort));
}

sub _upload {
  my ($ctx) = @_;
  return Iczelia::Upload->new(
    db      => $ctx->db,
    tmp_dir => $ctx->cfg->{'tmp-dir'} || '/tmp',
  );
}

sub _init {
  my ($ctx, $req) = @_;
  if (my $err = $ctx->auth->require_csrf($req, 'upload')) { return $err }
  my $u  = _upload($ctx);
  my $id = eval { $u->init($req->{auth_sid},
    filename => substr($req->{params}{filename} // '', 0, 255)) };
  return _json(500, {error => 'init failed'}) unless defined $id;
  return _json(200, {id => $id});
}

sub _chunk {
  my ($ctx, $req) = @_;
  if (my $err = $ctx->auth->require_csrf($req, 'upload')) { return $err }
  my $id     = $req->{params}{id} // '';
  my $offset = $req->{params}{offset};
  return _json(400, {error => 'bad id'})
    unless $id =~ /^[0-9a-f]{32,96}\z/;
  return _json(400, {error => 'bad offset'})
    unless defined $offset && $offset =~ /^(\d+)$/;
  $offset = $1 + 0;
  my $bytes = $req->{body};
  return _json(400, {error => 'empty chunk'})
    unless defined $bytes && length $bytes;
  my $u = _upload($ctx);
  my ($size, $err) = $u->append($id, $req->{auth_sid}, $offset, $bytes);
  return _json(400, {error => $err}) if $err;
  return _json(200, {size => $size + 0});
}

sub _abort {
  my ($ctx, $req) = @_;
  if (my $err = $ctx->auth->require_csrf($req, 'upload')) { return $err }
  my $id = $req->{params}{id} // '';
  return _json(400, {error => 'bad id'})
    unless $id =~ /^[0-9a-f]{32,96}\z/;
  _upload($ctx)->cleanup($id, $req->{auth_sid});
  return _json(200, {ok => JSON::PP::true});
}

sub _json {
  my ($status, $data) = @_;
  return {
    status  => $status,
    headers => {
      'Content-Type'  => 'application/json',
      'Cache-Control' => 'no-store',
    },
    body      => $JSON->encode($data),
    _no_cache => 1,
  };
}

1;
