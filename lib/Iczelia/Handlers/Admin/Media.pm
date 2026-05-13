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

package Iczelia::Handlers::Admin::Media;
use strict;
use warnings;
use JSON::PP      ();
use Iczelia::HTTP ();
use Iczelia::Media();
use Iczelia::Time qw(ts_fmt);

use constant MEDIA_BODY_MAX => 4 * 1024 * 1024;

my %ALLOWED_IMG_CT = (
  'image/png'  => 'png',
  'image/jpeg' => 'jpg',
  'image/gif'  => 'gif',
  'image/webp' => 'webp',
);

my $JSON = JSON::PP->new->utf8(0);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  $router->get('/admin/media/',             $gate->(\&_media_list));
  $router->post('/admin/media/upload',      $gate->(\&_media_upload));
  $router->post('/admin/media/:id/delete',  $gate->(\&_media_delete));
}

sub _media_list {
  my ($ctx, $req) = @_;
  my $rows = $ctx->content->list_media;
  my $sid = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{url} = '/media/' . $r->{filename};
    $r->{thumb_url} =
      $r->{thumb_filename}
      ? '/media/' . $r->{thumb_filename}
      : $r->{url};
    $r->{date_fmt} = ts_fmt($r->{uploaded_at});
    $r->{size_kb}  = sprintf('%.0f', ($r->{size} || 0) / 1024);
    $r->{csrf_del} = $ctx->auth->csrf_token($sid, "media:del:$r->{id}");
  }
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_media.tpl',
    title => 'media',
    items => $rows,
  );
}

sub _media_upload {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'upload');
  return $err if $err;

  my @files = @{$req->{uploads} || []};
  return _json_err(400, 'no file') unless @files;
  my $f = $files[0];

  return _json_err(413, 'too large') if $f->{size} > MEDIA_BODY_MAX;

  my $ct = lc $f->{content_type};
  $ct =~ s/;.*$//;
  $ct =~ s/\s+//g;
  my $ext = $ALLOWED_IMG_CT{$ct}
    or return _json_err(415, "unsupported type: $ct");

  require Digest::SHA;
  my $sha  = Digest::SHA::sha256_hex($f->{body});
  my $name = "$sha.$ext";
  my $dir  = $ctx->cfg->{'media-dir'};
  require File::Path;
  File::Path::make_path($dir) unless -d $dir;
  my $path   = "$dir/$name";
  my $is_new = !(-e $path);

  if ($is_new) {

    # The .$$ tmp suffix lets two simultaneous uploads of the same
    # SHA write to disjoint scratch files.
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return _json_err(500, "write: $!");
    print $fh $f->{body};
    close $fh;
    rename $tmp, $path;
  }

  # Best-effort: optimise PNGs and produce a 400x300 thumbnail. Either
  # step may fail silently; the original always serves.
  my $thumb_filename;
  if ($is_new) {
    if ($ext eq 'png') {
      eval {Iczelia::Media::optimize_png($path); 1};
    }
    my $thumb = Iczelia::Media::thumb_filename_for($name);
    if ($thumb) {
      my $thumb_path = "$dir/$thumb";
      my $ok         = eval {Iczelia::Media::make_thumb($path, $thumb_path)};
      $thumb_filename = $thumb if $ok;
    }
  }

  $ctx->content->create_media(
    filename       => $name,
    orig_name      => $f->{filename},
    content_type   => $ct,
    size           => $f->{size},
    sha256         => $sha,
    thumb_filename => $thumb_filename,
  );

  return _json_ok({url => "/media/$name", filename => $name});
}

sub _media_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->auth->require_csrf($req, "media:del:$id");
  return $err if $err;
  my $row = $ctx->content->get_media($id);
  if ($row) {
    my $dir = $ctx->cfg->{'media-dir'};

    # _media_upload always writes <sha256>.<ext>; refuse anything
    # else here as defense in depth against DB tampering.
    for my $fn (grep {defined && length} $row->{filename},
      $row->{thumb_filename})
    {
      next unless $fn =~ /^[0-9a-f]{64}(?:\.thumb)?\.(?:png|jpg|gif|webp)$/;
      my $path = "$dir/$fn";
      unlink $path if -e $path;
    }
  }
  $ctx->content->delete_media($id);
  return Iczelia::HTTP::redirect('/admin/media/');
}

sub _json_ok {
  my $data = shift;
  return {
    status  => 200,
    headers => {'Content-Type' => 'application/json'},
    body    => $JSON->encode($data),
  };
}

sub _json_err {
  my ($status, $msg) = @_;
  return {
    status  => $status,
    headers => {'Content-Type' => 'application/json'},
    body    => $JSON->encode({error => $msg}),
  };
}

1;
