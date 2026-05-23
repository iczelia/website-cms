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

package Iczelia::Handlers::Admin::Subpages;
use strict;
use warnings;
use JSON::PP          ();
use Encode            ();
use Iczelia::HTTP     ();
use Iczelia::Subpages ();
use Iczelia::Time     qw(ts_fmt);

my $JSON = JSON::PP->new->utf8(0);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  $router->get('/admin/subpages/',  $gate->(\&_list));
  $router->post('/admin/subpages/new', $gate->(\&_create));
  $router->get('/admin/subpages/:id/edit',   $gate->(\&_edit));
  $router->post('/admin/subpages/:id/meta',  $gate->(\&_meta));
  $router->post('/admin/subpages/:id/rezip', $gate->(\&_rezip));
  $router->post('/admin/subpages/:id/delete', $gate->(\&_delete));
  $router->get('/admin/subpages/:id/file',         $gate->(\&_file_get));
  $router->post('/admin/subpages/:id/file/save',   $gate->(\&_file_save));
  $router->post('/admin/subpages/:id/file/upload', $gate->(\&_file_upload));
  $router->post('/admin/subpages/:id/file/delete', $gate->(\&_file_delete));
}

sub _list {_render_list(@_)}

sub _render_list {
  my ($ctx, $req, %opt) = @_;
  my $sid  = $req->{auth_sid};
  my $rows = Iczelia::Subpages::list($ctx->db);
  for my $r (@$rows) {
    $r->{url}         = "/$r->{slug}/";
    $r->{updated_fmt} = ts_fmt($r->{updated_at});
    $r->{csrf_del}    = $ctx->auth->csrf_token($sid, "subpage:del:$r->{id}");
  }
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_subpages_list.tpl',
    title       => 'static subpages',
    subpages    => $rows,
    error          => $opt{error},
    slug_value     => (defined $opt{slug}     ? $opt{slug}     : ''),
    title_value    => (defined $opt{title}    ? $opt{title}    : ''),
    zip_path_value => (defined $opt{zip_path} ? $opt{zip_path} : ''),
    csrf_form      => $ctx->auth->csrf_token($sid, 'subpage:new'),
  );
}

sub _create {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'subpage:new');
  return $err if $err;

  my $slug  = _norm_slug($req->{params}{slug});
  my $title = defined $req->{params}{title} ? $req->{params}{title} : '';
  my @form  = (
    slug => $slug, title => $title,
    zip_path => $req->{params}{zip_path},
  );

  return _render_list($ctx, $req, @form,
    error => 'invalid slug: use a-z, 0-9 and dashes, and avoid reserved names')
    unless Iczelia::Subpages::valid_slug($slug);
  return _render_list($ctx, $req, @form,
    error => "the slug '$slug' is already in use")
    if _slug_taken($ctx, $slug, 0);

  my ($zip, $src_err, $from_fs) = _bundle_bytes($req);
  return _render_list($ctx, $req, @form, error => $src_err) if $src_err;
  return _render_list($ctx, $req, @form,
    error => 'attach a .zip bundle or import one from a server path')
    unless defined $zip;

  my ($files, $zerr) =
    Iczelia::Subpages::extract_zip($zip, unlimited => $from_fs);
  return _render_list($ctx, $req, @form, error => "zip: $zerr") if $zerr;

  my $id = Iczelia::Subpages::create($ctx->db, $slug, $title, $files);
  return Iczelia::HTTP::redirect("/admin/subpages/$id/edit");
}

sub _edit {_render_edit(@_)}

sub _render_edit {
  my ($ctx, $req, %opt) = @_;
  my $id = _id($req);
  my $sp = Iczelia::Subpages::get($ctx->db, $id)
    or return Iczelia::HTTP::error(404);
  my $sid   = $req->{auth_sid};
  my $files = Iczelia::Subpages::files($ctx->db, $id);
  my $has_index = 0;
  for my $f (@$files) {
    $f->{size_fmt} = _fmt_size($f->{size});
    $f->{editable} = $f->{is_binary} ? 0 : 1;
    $has_index = 1 if $f->{path} eq 'index.html';
  }
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_subpages_edit.tpl',
    title      => "subpage: $sp->{slug}",
    sp         => $sp,
    sp_url     => "/$sp->{slug}/",
    files      => $files,
    file_count => scalar(@$files),
    no_index   => ($has_index ? 0 : 1),
    error      => $opt{error},
    notice     => $opt{notice},
    csrf_extra => {
      meta  => $ctx->auth->csrf_token($sid, "subpage:meta:$id"),
      rezip => $ctx->auth->csrf_token($sid, "subpage:rezip:$id"),
      del   => $ctx->auth->csrf_token($sid, "subpage:del:$id"),
      file  => $ctx->auth->csrf_token($sid, "subpage:file:$id"),
    },
  );
}

sub _meta {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  Iczelia::Subpages::get($ctx->db, $id) or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "subpage:meta:$id");
  return $err if $err;

  my $slug    = _norm_slug($req->{params}{slug});
  my $title   = defined $req->{params}{title} ? $req->{params}{title} : '';
  my $listing = $req->{params}{listing} ? 1 : 0;
  return _render_edit($ctx, $req,
    error => 'invalid slug: use a-z, 0-9 and dashes')
    unless Iczelia::Subpages::valid_slug($slug);
  return _render_edit($ctx, $req, error => "the slug '$slug' is already in use")
    if _slug_taken($ctx, $slug, $id);

  Iczelia::Subpages::update_meta($ctx->db, $id, $slug, $title, $listing);
  return Iczelia::HTTP::redirect("/admin/subpages/$id/edit");
}

sub _rezip {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  Iczelia::Subpages::get($ctx->db, $id) or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "subpage:rezip:$id");
  return $err if $err;

  my ($zip, $src_err, $from_fs) = _bundle_bytes($req);
  return _render_edit($ctx, $req, error => $src_err) if $src_err;
  return _render_edit($ctx, $req,
    error => 'attach a .zip bundle or import one from a server path')
    unless defined $zip;
  my ($files, $zerr) =
    Iczelia::Subpages::extract_zip($zip, unlimited => $from_fs);
  return _render_edit($ctx, $req, error => "zip: $zerr") if $zerr;

  Iczelia::Subpages::replace_files($ctx->db, $id, $files);
  return _render_edit($ctx, $req, notice => 'bundle replaced');
}

sub _delete {
  my ($ctx, $req) = @_;
  my $id  = _id($req);
  my $err = $ctx->auth->require_csrf($req, "subpage:del:$id");
  return $err if $err;
  Iczelia::Subpages::delete($ctx->db, $id);
  return Iczelia::HTTP::redirect('/admin/subpages/');
}

sub _file_get {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  Iczelia::Subpages::get($ctx->db, $id) or return Iczelia::HTTP::error(404);
  my $path = defined $req->{qparams}{path} ? $req->{qparams}{path} : '';
  my $f = Iczelia::Subpages::file($ctx->db, $id, $path)
    or return Iczelia::HTTP::error(404);

  # Text files go back as text/plain so the browser never executes the
  # admin's own bundle markup in the panel's origin.
  my $ct =
    $f->{is_binary} ? $f->{content_type} : 'text/plain; charset=utf-8';
  return {
    status  => 200,
    headers => {
      'Content-Type'           => $ct,
      'Cache-Control'          => 'no-store',
      'X-Content-Type-Options' => 'nosniff',
    },
    body => $f->{content},
  };
}

sub _file_save {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  Iczelia::Subpages::get($ctx->db, $id)
    or return _json(404, {error => 'subpage not found'});
  return _json(400, {error => 'csrf check failed'})
    if $ctx->auth->require_csrf($req, "subpage:file:$id");

  my $path = defined $req->{params}{path} ? $req->{params}{path} : '';
  my $content = defined $req->{params}{content} ? $req->{params}{content} : '';
  $content = Encode::encode('UTF-8', $content) if Encode::is_utf8($content);
  return _json(413, {error => 'file too large'})
    if length($content) > Iczelia::Subpages::MAX_FILE;

  my $rel = Iczelia::Subpages::put_file($ctx->db, $id, $path, $content);
  return _json(400, {error => 'invalid file path'}) unless defined $rel;
  return _json(200, {ok => JSON::PP::true, path => $rel});
}

sub _file_upload {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  Iczelia::Subpages::get($ctx->db, $id) or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "subpage:file:$id");
  return $err if $err;

  my @up = @{$req->{uploads} || []};
  return _render_edit($ctx, $req, error => 'choose a file to upload')
    unless @up && defined $up[0]{body} && length $up[0]{body};
  return _render_edit($ctx, $req, error => 'file too large')
    if length($up[0]{body}) > Iczelia::Subpages::MAX_FILE;

  my $path = $req->{params}{path};
  $path = $up[0]{filename} unless defined $path && length $path;
  my $rel = Iczelia::Subpages::put_file($ctx->db, $id, $path, $up[0]{body});
  return _render_edit($ctx, $req, error => 'invalid file path')
    unless defined $rel;
  return Iczelia::HTTP::redirect("/admin/subpages/$id/edit");
}

sub _file_delete {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  Iczelia::Subpages::get($ctx->db, $id) or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "subpage:file:$id");
  return $err if $err;
  my $path = $req->{params}{path};
  Iczelia::Subpages::delete_file($ctx->db, $id, $path)
    if defined $path && length $path;
  return Iczelia::HTTP::redirect("/admin/subpages/$id/edit");
}

sub _id {
  my ($req) = @_;
  my $id = $req->{caps}{id};
  return (defined $id && $id =~ /^(\d+)$/) ? $1 + 0 : 0;
}

sub _norm_slug {
  my ($s) = @_;
  $s = '' unless defined $s;
  $s =~ s/^\s+//;
  $s =~ s/\s+$//;
  return lc $s;
}

# A slug collides if another subpage or a dynamic page already owns it.
sub _slug_taken {
  my ($ctx, $slug, $exclude_id) = @_;
  my $sp = Iczelia::Subpages::get_by_slug($ctx->db, $slug);
  return 1 if $sp && $sp->{id} != ($exclude_id || 0);
  return 1
    if $ctx->db->row('SELECT 1 FROM dynamic_pages WHERE route=?', "/$slug/");
  return 0;
}

# Bundle bytes for create / rezip: an uploaded file, or a .zip on the
# server's filesystem. Returns ($bytes, $error, $from_fs); a filesystem
# import is uncapped, so $from_fs drives the extract_zip limit bypass.
sub _bundle_bytes {
  my ($req) = @_;

  my @up = @{$req->{uploads} || []};
  return ($up[0]{body}, undef, 0)
    if @up && defined $up[0]{body} && length $up[0]{body};

  my $path = $req->{params}{zip_path};
  return (undef, undef, 0) unless defined $path && $path =~ /\S/;
  $path =~ s/^\s+//;
  $path =~ s/\s+$//;

  return (undef, 'the server path must be absolute')
    unless $path =~ m{^/} && $path !~ /\0/;
  return (undef, "no file at $path")              unless -e $path;
  return (undef, 'the server path is not a file') unless -f _;
  return (undef, 'the server file is not readable by the daemon')
    unless -r _;

  open my $fh, '<:raw', $path
    or return (undef, 'could not open the server file');
  local $/;
  my $data = <$fh>;
  close $fh;
  return (undef, 'the server file is empty')
    unless defined $data && length $data;
  return ($data, undef, 1);
}

sub _fmt_size {
  my ($n) = @_;
  $n ||= 0;
  return "$n B" if $n < 1024;
  return sprintf('%.1f KB', $n / 1024) if $n < 1024 * 1024;
  return sprintf('%.1f MB', $n / 1048576);
}

sub _json {
  my ($status, $data) = @_;
  return {
    status  => $status,
    headers =>
      {'Content-Type' => 'application/json', 'Cache-Control' => 'no-store'},
    body => $JSON->encode($data),
  };
}

1;
