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
use Iczelia::Upload   ();
use Iczelia::Time     qw(ts_fmt);
use Iczelia::Util     qw(escape_url);

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
    slug_value     => (defined $opt{slug}  ? $opt{slug}  : ''),
    title_value    => (defined $opt{title} ? $opt{title} : ''),
    csrf_form      => $ctx->auth->csrf_token($sid, 'subpage:new'),
  );
}

sub _bust {
  my ($ctx, @slugs) = @_;
  eval {$ctx->render->invalidate_subpage(@slugs); 1}
    or warn "subpage cache invalidation failed: $@";
}

sub _create {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'subpage:new');
  return $err if $err;

  my $slug  = _norm_slug($req->{params}{slug});
  my $title = defined $req->{params}{title} ? $req->{params}{title} : '';
  my @form  = (slug => $slug, title => $title);

  return _render_list($ctx, $req, @form,
    error => 'invalid slug: use a-z, 0-9 and dashes, and avoid reserved names')
    unless Iczelia::Subpages::valid_slug($slug);
  return _render_list($ctx, $req, @form,
    error => "the slug '$slug' is already in use")
    if _slug_taken($ctx, $slug, 0);

  my ($zip, $src_err, $unlimited) = _bundle_bytes($ctx, $req);
  return _render_list($ctx, $req, @form, error => $src_err) if $src_err;
  return _render_list($ctx, $req, @form,
    error => 'attach a .zip bundle (chunked uploader handles any size)')
    unless defined $zip;

  my ($files, $zerr) =
    Iczelia::Subpages::extract_zip($zip, unlimited => $unlimited);
  return _render_list($ctx, $req, @form, error => "zip: $zerr") if $zerr;

  my $id = Iczelia::Subpages::create($ctx->db, $slug, $title, $files);
  _bust($ctx, $slug);
  return Iczelia::HTTP::redirect("/admin/subpages/$id/edit");
}

sub _edit {_render_edit(@_)}

sub _render_edit {
  my ($ctx, $req, %opt) = @_;
  my $id = _id($req);
  my $sp = Iczelia::Subpages::get($ctx->db, $id)
    or return Iczelia::HTTP::error(404);
  my $sid = $req->{auth_sid};

  my $raw_dir =
      exists $opt{dir} ? $opt{dir}
    :                    ($req->{qparams}{dir} // $req->{params}{dir} // '');
  my $dir = _norm_dir($raw_dir);
  $dir = '' unless defined $dir;

  my $has_index = Iczelia::Subpages::file($ctx->db, $id, 'index.html') ? 1 : 0;
  my $file_total = Iczelia::Subpages::file_count($ctx->db, $id);

  my $entries = Iczelia::Subpages::directory_entries($ctx->db, $id, $dir);

  # The README block above the listing - same rule as the public view,
  # scoped to the current directory.
  my $readme;
  for my $e (@$entries) {
    next if $e->{type} ne 'file';
    next unless Iczelia::Subpages::is_readme_name($e->{name});
    my $row = Iczelia::Subpages::file($ctx->db, $id, $e->{path});
    if ($row) {
      my $bytes   = $row->{content};
      my $decoded = eval {
        Encode::decode('UTF-8', $bytes, Encode::FB_CROAK());
      };
      $readme = {
        name    => $e->{name},
        content => (defined $decoded ? $decoded : $bytes),
      };
    }
    last;
  }

  my $base = "/admin/subpages/$id/edit";
  my @rows;
  if (length $dir) {
    my $parent = $dir;
    $parent =~ s{/?[^/]+\z}{};
    push @rows, {
      is_dir    => 1,
      is_file   => 0,
      is_parent => 1,
      name      => 'Parent Directory',
      icon      => 'folder.png',
      href      => $base . (length $parent ? '?dir=' . escape_url($parent) : ''),
      mtime     => '-',
      size      => '-',
    };
  }
  for my $e (@$entries) {
    if ($e->{type} eq 'dir') {
      my $child = length($dir) ? "$dir/$e->{name}" : $e->{name};
      push @rows, {
        is_dir    => 1,
        is_file   => 0,
        is_parent => 0,
        name      => $e->{name} . '/',
        icon      => 'folder.png',
        href      => $base . '?dir=' . escape_url($child),
        mtime     => Iczelia::Subpages::fmt_mtime($e->{updated_at}),
        size      => '-',
      };
    }
    else {
      push @rows, {
        is_dir       => 0,
        is_file      => 1,
        is_parent    => 0,
        name         => $e->{name},
        icon         => Iczelia::Subpages::icon_for_entry($e->{name},
          content_type => $e->{content_type}, is_binary => $e->{is_binary},
          lang => $e->{lang}),
        path         => $e->{path},
        mtime        => Iczelia::Subpages::fmt_mtime($e->{updated_at}),
        size         => Iczelia::Subpages::fmt_size($e->{size}),
        content_type => $e->{content_type},
        editable     => ($e->{is_binary} ? 0 : 1),
        view_url     =>
          "/admin/subpages/$id/file?path=" . escape_url($e->{path}),
        public_url   => "/$sp->{slug}/" . _public_path($e->{path}),
      };
    }
  }

  # Breadcrumb segments: { label, href }.
  my @crumbs = ({label => "/$sp->{slug}/", href => $base});
  if (length $dir) {
    my @segs = split m{/}, $dir;
    my $acc = '';
    for my $i (0 .. $#segs) {
      $acc = length($acc) ? "$acc/$segs[$i]" : $segs[$i];
      push @crumbs, {
        label => $segs[$i] . '/',
        href  => $base . '?dir=' . escape_url($acc),
      };
    }
  }
  $crumbs[-1]{current} = 1;

  my $public_url = "/$sp->{slug}/" . (length $dir ? "$dir/" : '');

  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_subpages_edit.tpl',
    title       => "subpage: $sp->{slug}",
    sp          => $sp,
    sp_url      => "/$sp->{slug}/",
    dir         => $dir,
    dir_url     => $public_url,
    is_root     => (length $dir ? 0 : 1),
    crumbs      => \@crumbs,
    rows        => \@rows,
    empty       => (@rows ? 0 : 1),
    file_count  => $file_total,
    no_index    => ($has_index ? 0 : 1),
    readme      => $readme,
    error       => $opt{error},
    notice      => $opt{notice},
    upload_path_hint => (length $dir ? "$dir/" : ''),
    new_file_path_hint => (length $dir ? "$dir/" : ''),
    csrf_extra  => {
      meta  => $ctx->auth->csrf_token($sid, "subpage:meta:$id"),
      rezip => $ctx->auth->csrf_token($sid, "subpage:rezip:$id"),
      del   => $ctx->auth->csrf_token($sid, "subpage:del:$id"),
      file  => $ctx->auth->csrf_token($sid, "subpage:file:$id"),
    },
  );
}

sub _public_path {
  my ($path) = @_;
  return '' unless defined $path;
  return join '/', map {escape_url($_)} split m{/}, $path;
}

sub _norm_dir {
  my ($s) = @_;
  return '' unless defined $s;
  $s =~ s{^/+}{};
  $s =~ s{/+$}{};
  return '' unless length $s;
  my $clean = Iczelia::Subpages::sanitize_rel_path($s);
  return defined $clean ? $clean : '';
}

sub _edit_url {
  my ($id, $dir) = @_;
  my $u = "/admin/subpages/$id/edit";
  $u .= '?dir=' . escape_url($dir) if defined $dir && length $dir;
  return $u;
}

sub _meta {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $sp = Iczelia::Subpages::get($ctx->db, $id)
    or return Iczelia::HTTP::error(404);
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

  # A rename strands the old prefix, whose URLs now 404.
  _bust($ctx, $slug, $sp->{slug});
  return Iczelia::HTTP::redirect("/admin/subpages/$id/edit");
}

sub _rezip {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $sp = Iczelia::Subpages::get($ctx->db, $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "subpage:rezip:$id");
  return $err if $err;

  my ($zip, $src_err, $unlimited) = _bundle_bytes($ctx, $req);
  return _render_edit($ctx, $req, error => $src_err) if $src_err;
  return _render_edit($ctx, $req,
    error => 'attach a .zip bundle (chunked uploader handles any size)')
    unless defined $zip;
  my ($files, $zerr) =
    Iczelia::Subpages::extract_zip($zip, unlimited => $unlimited);
  return _render_edit($ctx, $req, error => "zip: $zerr") if $zerr;

  Iczelia::Subpages::replace_files($ctx->db, $id, $files);
  _bust($ctx, $sp->{slug});
  return _render_edit($ctx, $req, notice => 'bundle replaced');
}

sub _delete {
  my ($ctx, $req) = @_;
  my $id  = _id($req);
  my $err = $ctx->auth->require_csrf($req, "subpage:del:$id");
  return $err if $err;

  # Read the slug before the row goes; it is the handle on the cache.
  my $sp = Iczelia::Subpages::get($ctx->db, $id);
  Iczelia::Subpages::delete($ctx->db, $id);
  _bust($ctx, $sp->{slug}) if $sp;
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
  my $sp = Iczelia::Subpages::get($ctx->db, $id)
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
  _bust($ctx, $sp->{slug});
  return _json(200, {ok => JSON::PP::true, path => $rel});
}

sub _file_upload {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $sp = Iczelia::Subpages::get($ctx->db, $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "subpage:file:$id");
  return $err if $err;

  my $dir = _norm_dir($req->{params}{dir});
  my $batch = $req->{params}{batch} ? 1 : 0;
  my ($files, $prep_err, $unlimited) = _uploaded_files($ctx, $req, $dir);
  return $batch
    ? _json(400, {error => $prep_err})
    : _render_edit($ctx, $req, dir => $dir, error => $prep_err)
    if $prep_err;

  my ($paths, $put_err) = Iczelia::Subpages::put_files(
    $ctx->db, $id, $files, unlimited => $unlimited,
  );
  if ($put_err) {
    my $status = $put_err =~ /too large/ ? 413 : 400;
    return $batch
      ? _json($status, {error => $put_err})
      : _render_edit($ctx, $req, dir => $dir, error => $put_err);
  }
  _bust($ctx, $sp->{slug});
  return _json(200, {
    ok    => JSON::PP::true,
    count => scalar(@$paths),
    paths => $paths,
  }) if $batch;
  return Iczelia::HTTP::redirect(_edit_url($id, $dir));
}

sub _uploaded_files {
  my ($ctx, $req, $dir) = @_;
  my @up = grep {
    length($_->{filename} // '') || length($_->{body} // '')
  } @{$req->{uploads} || []};
  my $unlimited = 0;

  my $upload_id = $req->{params}{upload_id};
  if (defined $upload_id && length $upload_id) {
    return (undef, 'only one chunked file can be finalized at a time', 0)
      if @up;
    my $u = Iczelia::Upload->new(
      db      => $ctx->db,
      tmp_dir => $ctx->cfg->{'tmp-dir'} || '/tmp',
    );
    my (undef, $ferr) = $u->finalize($upload_id, $req->{auth_sid});
    return (undef, "upload: $ferr", 0) if $ferr;
    my ($tmp, $cerr) = $u->claim($upload_id, $req->{auth_sid});
    return (undef, "upload: $cerr", 0) if $cerr;
    open my $fh, '<:raw', $tmp or do {
      my $e = $!;
      $u->cleanup($upload_id, $req->{auth_sid});
      return (undef, "upload: open: $e", 0);
    };
    local $/;
    my $body = <$fh>;
    close $fh;
    $u->cleanup($upload_id, $req->{auth_sid});
    push @up, {
      name     => 'files',
      filename => $req->{params}{path} // '',
      body     => (defined $body ? $body : ''),
    };
    $unlimited = 1;
  }

  return (undef, 'choose one or more files to upload', 0) unless @up;

  my $paths_json = $req->{params}{paths};
  my $paths;
  if (defined $paths_json && length $paths_json) {
    $paths = eval {$JSON->decode($paths_json)};
    return (undef, 'invalid upload path list', 0)
      unless ref($paths) eq 'ARRAY' && @$paths == @up;
  }

  my $explicit = $req->{params}{path};
  return (undef, 'the path override can only be used with one file', 0)
    if defined $explicit && length $explicit && @up != 1 && !$paths;

  my @files;
  for my $i (0 .. $#up) {
    my $u = $up[$i];
    return (undef, 'invalid empty upload', 0) unless defined $u->{body};

    my $path;
    if ($paths) {
      return (undef, 'invalid upload path list', 0)
        if ref($paths->[$i]);
      $path = _under_dir($dir, $paths->[$i]);
    }
    elsif (defined $explicit && length $explicit) {
      # Preserve the old single-file behavior: a path containing a slash is
      # bundle-root-relative, while a bare name lands in the open directory.
      $path = $explicit;
      $path = _under_dir($dir, $path) if $path !~ m{/};
    }
    else {
      $path = $u->{filename};
      # Directory inputs retain their relative path. Normal file inputs are
      # reduced to a basename so a client-supplied fake path cannot escape
      # the directory selected in the panel.
      if (($u->{name} // '') ne 'directory') {
        $path =~ s{.*[\\/]}{} if defined $path;
      }
      $path = _under_dir($dir, $path);
    }
    push @files, {path => $path, content => $u->{body}};
  }
  return (\@files, undef, $unlimited);
}

sub _under_dir {
  my ($dir, $path) = @_;
  $path = '' unless defined $path;
  $path =~ s{^[\\/]+}{};
  return length($dir) ? "$dir/$path" : $path;
}

sub _file_delete {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $sp = Iczelia::Subpages::get($ctx->db, $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "subpage:file:$id");
  return $err if $err;
  my $dir  = _norm_dir($req->{params}{dir});
  my $path = $req->{params}{path};
  if (defined $path && length $path) {
    Iczelia::Subpages::delete_file($ctx->db, $id, $path);
    _bust($ctx, $sp->{slug});
  }
  return Iczelia::HTTP::redirect(_edit_url($id, $dir));
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

# Bundle bytes for create / rezip. Two sources:
#   (a) /admin/upload/* chunked session via params.upload_id -- this is
#       the recommended path for anything over the request-cap, and
#       counts as unlimited (the upload module owns its own size cap).
#   (b) classic multipart file upload (small bundles, JS off).
# Returns ($bytes, $error, $unlimited_flag).
sub _bundle_bytes {
  my ($ctx, $req) = @_;

  my $upload_id = $req->{params}{upload_id};
  if (defined $upload_id && length $upload_id) {
    my $u = Iczelia::Upload->new(
      db      => $ctx->db,
      tmp_dir => $ctx->cfg->{'tmp-dir'} || '/tmp',
    );
    $u->finalize($upload_id, $req->{auth_sid});
    my ($path, $cerr) = $u->claim($upload_id, $req->{auth_sid});
    return (undef, "upload: $cerr") if $cerr;
    open my $fh, '<:raw', $path or do {
      $u->cleanup($upload_id, $req->{auth_sid});
      return (undef, "open: $!");
    };
    local $/;
    my $data = <$fh>;
    close $fh;
    $u->cleanup($upload_id, $req->{auth_sid});
    return (undef, 'upload was empty')
      unless defined $data && length $data;
    return ($data, undef, 1);
  }

  my @up = @{$req->{uploads} || []};
  return ($up[0]{body}, undef, 0)
    if @up && defined $up[0]{body} && length $up[0]{body};

  return (undef, undef, 0);
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
