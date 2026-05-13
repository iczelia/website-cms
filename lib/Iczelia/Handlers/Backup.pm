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

package Iczelia::Handlers::Backup;
use strict;
use warnings;
use Iczelia::HTTP ();
use Iczelia::Util qw(escape_url);
use File::Path    qw(make_path remove_tree);
use File::Spec    ();
use File::Copy    qw(move);
use Digest::SHA   qw(sha256_hex);
use JSON::PP      ();
use DBI           ();
use Archive::Tar  ();

# Backup: VACUUM INTO snapshot, ephemeral tables stripped, tar with
# media/. Restore atomically swaps the live DB and media/ tree.

# Tables whose contents are tied to the running instance (cache,
# session, throttle counters) and are wiped from snapshots.
my @EPHEMERAL_TABLES = qw(
  response_cache tex_cache sessions login_throttle guestbook_throttle
);

my $JSON = JSON::PP->new->utf8(1)->canonical(1)->pretty(1);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  $router->get('/admin/backup/', $gate->(\&_form));
  $router->post('/admin/backup/export', $gate->(\&_export));
  $router->post('/admin/backup/import', $gate->(\&_import));
  $router->post('/admin/backup/wipe',   $gate->(\&_wipe));
}

sub _form {
  my ($ctx, $req) = @_;
  require Iczelia::Handlers::Admin;
  my $sid = $req->{auth_sid};
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_backup.tpl',
    title => 'backup / wipe',
    csrf  => {
      export => $ctx->auth->csrf_token($sid, 'backup:export'),
      import => $ctx->auth->csrf_token($sid, 'backup:import'),
      wipe   => $ctx->auth->csrf_token($sid, 'backup:wipe'),
    },
    flash => $req->{qparams}{msg}
    ? {kind => 'ok', text => $req->{qparams}{msg}}
    : undef,
  );
}

sub _export {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'backup:export');
  return $err if $err;

  my $tmp_dir = $ctx->cfg->{'tmp-dir'} || '/tmp';
  make_path($tmp_dir) unless -d $tmp_dir;
  my $stamp = _date_stamp();
  my $work  = "$tmp_dir/iczelia-export-$stamp.$$";
  make_path($work);

  my $snap = "$work/site.db";
  eval {
    $ctx->db->dbh->do(q{VACUUM INTO ?}, undef, $snap);
    my $tdb = DBI->connect("dbi:SQLite:dbname=$snap", '', '',
      {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    eval {$tdb->do("DELETE FROM $_")} for @EPHEMERAL_TABLES;
    $tdb->do('VACUUM');
    $tdb->disconnect;
    1;
  } or do {
    remove_tree($work);
    return Iczelia::HTTP::error(500, "snapshot failed: $@");
  };

  my $media_src   = $ctx->cfg->{'media-dir'};
  my @media_files = _list_dir_files($media_src);

  my $manifest = $JSON->encode(
    {
      version     => 1,
      date        => _iso_date(),
      db_sha256   => _sha256_file($snap),
      media_count => scalar(@media_files),
    }
  );

  # Build the tar archive in memory via Archive::Tar; no shell-out.
  my $tar = Archive::Tar->new;
  $tar->add_data('site.db',       _slurp_raw($snap));
  $tar->add_data('MANIFEST.json', $manifest);
  for my $fn (@media_files) {
    my $data = eval {_slurp_raw("$media_src/$fn")};
    next unless defined $data;
    $tar->add_data("media/$fn", $data);
  }
  my $body = $tar->write;
  remove_tree($work);
  return Iczelia::HTTP::error(500, "tar build failed") unless defined $body;

  return {
    status  => 200,
    headers => {
      'Content-Type'        => 'application/x-tar',
      'Content-Disposition' =>
        qq{attachment; filename="iczelia-backup-$stamp.tar"},
      'Cache-Control' => 'no-store',
    },
    body      => $body,
    _no_cache => 1,
  };
}

# Extract every entry from $tar_path into $dest_dir, preserving the
# entry's relative path. Path-safety is asserted by the caller via
# _archive_paths_safe; this helper double-checks each entry as defense
# in depth. Returns 1 on success, 0 on any failure.
sub _extract_archive {
  my ($tar_path, $dest_dir) = @_;
  my $iter = eval {Archive::Tar->iter($tar_path)};
  return 0 unless $iter;
  while (my $entry = eval {$iter->()}) {
    next if $entry->is_dir;
    my $name = $entry->full_path;
    return 0 unless defined $name && length $name;
    return 0 if $name =~ m{^/} || $name =~ m{(?:^|/)\.\.(?:/|$)};
    my $target = "$dest_dir/$name";
    my ($dir)  = $target =~ m{^(.+)/[^/]+$};
    if (defined $dir && !-d $dir) {
      eval {make_path($dir)} or return 0;
    }
    $entry->extract($target) or return 0;
  }
  return 1;
}

sub _slurp_raw {
  my ($path) = @_;
  open my $fh, '<:raw', $path or die "open $path: $!";
  local $/;
  my $data = <$fh>;
  close $fh;
  return $data;
}

sub _list_dir_files {
  my ($dir) = @_;
  return () unless $dir && -d $dir;
  opendir my $dh, $dir or return ();
  my @out = grep {!/^\./ && -f "$dir/$_"} readdir $dh;
  closedir $dh;
  return @out;
}

# Tar-bomb cap: well above any real backup, small enough that a hostile
# archive can't fill the tmp volume on extract.
use constant MAX_EXTRACTED => 512 * 1024 * 1024;

# Returns 1 if the archive is safe to extract: rejects absolute and
# `..` entries, and bails when the entry-size sum exceeds MAX_EXTRACTED.
# Archive::Tar's iterator gives raw byte-name entries directly, so
# there's no shell-out and no quoting-style edge case to parse.
sub _archive_paths_safe {
  my ($tar_path) = @_;
  my $iter = eval {Archive::Tar->iter($tar_path)};
  return 0 unless $iter;
  my $total = 0;
  while (my $entry = eval {$iter->()}) {
    my $name = $entry->full_path;
    return 0 unless defined $name && length $name;
    return 0 if $name =~ m{^/} || $name =~ m{(?:^|/)\.\.(?:/|$)};
    $total += $entry->size || 0;
    return 0 if $total > MAX_EXTRACTED;
  }
  return 1;
}

sub _import {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'backup:import');
  return $err if $err;
  my @files = @{$req->{uploads} || []};
  return Iczelia::HTTP::error(400, 'no file') unless @files;
  my $f = $files[0];

  my $tmp_dir = $ctx->cfg->{'tmp-dir'} || '/tmp';
  make_path($tmp_dir) unless -d $tmp_dir;
  my $work = "$tmp_dir/iczelia-import.$$";
  make_path($work);
  my $tar_path = "$work/upload.tar";
  open my $fh, '>:raw', $tar_path
    or do {remove_tree($work); return Iczelia::HTTP::error(500, "write: $!")};
  print $fh $f->{body};
  close $fh;

  unless (_archive_paths_safe($tar_path)) {
    remove_tree($work);
    return Iczelia::HTTP::error(400, 'archive contains unsafe paths');
  }
  unless (_extract_archive($tar_path, $work)) {
    remove_tree($work);
    return Iczelia::HTTP::error(400, 'tar extract failed');
  }
  my $snap = "$work/site.db";
  unless (-f $snap) {
    remove_tree($work);
    return Iczelia::HTTP::error(400, 'site.db missing in archive');
  }
  my $ok = eval {
    my $vdb = DBI->connect("dbi:SQLite:dbname=$snap", '', '',
      {RaiseError => 1, PrintError => 0});
    for my $t (qw(posts pages auth settings)) {
      $vdb->selectrow_array("SELECT 1 FROM $t LIMIT 1");
    }
    $vdb->disconnect;
    1;
  };
  unless ($ok) {
    remove_tree($work);
    return Iczelia::HTTP::error(400, 'archive failed validation');
  }

  my $live_path = $ctx->db->{path};
  eval {$ctx->db->disconnect};
  move($live_path, "$live_path.preimport") if -f $live_path;
  unless (move($snap, $live_path)) {
    my $err = "$!";
    remove_tree($work);
    move("$live_path.preimport", $live_path)
      if -e "$live_path.preimport";
    return Iczelia::HTTP::error(500, "rename: $err");
  }
  eval {$ctx->db->reconnect};

  my $media_src = "$work/media";
  my $media_dst = $ctx->cfg->{'media-dir'};
  if ($media_dst && -d $media_src) {
    make_path($media_dst) unless -d $media_dst;
    if (opendir my $dh, $media_dst) {
      for my $fn (readdir $dh) {
        next                    if $fn =~ /^\./;
        unlink "$media_dst/$fn" if -f "$media_dst/$fn";
      }
      closedir $dh;
    }
    if (opendir my $dh, $media_src) {
      for my $fn (readdir $dh) {
        next if $fn =~ /^\./;
        next if $fn =~ m{[/\\]};
        _copy_file("$media_src/$fn", "$media_dst/$fn");
      }
      closedir $dh;
    }
  }

  remove_tree($work);
  eval {$ctx->render->invalidate_all};
  return Iczelia::HTTP::redirect('/admin/backup/?msg=imported');
}

sub _wipe {
  my ($ctx, $req) = @_;
  if (my $reject = _wipe_validate_request($ctx, $req)) {
    return $reject;
  }
  my $share = $ctx->cfg->{'share-dir'}
    or return Iczelia::HTTP::error(500, 'share-dir not configured');
  my $auth_dump = $ctx->db->all('SELECT * FROM auth');

  # PRAGMA must be set outside any transaction; tx_immediate wraps the
  # wipe sequence. Operator must quiesce traffic first (admin UI says
  # so); sibling workers will hit table-not-found.
  $ctx->db->dbh->do('PRAGMA foreign_keys = OFF');
  my $err = _wipe_apply_schema($ctx, $share, $auth_dump);
  $ctx->db->dbh->do('PRAGMA foreign_keys = ON');
  if (defined $err) {
    warn "wipe failed: $err";
    return Iczelia::HTTP::error(500, "wipe failed: $err");
  }
  eval {$ctx->render->invalidate_all};
  _wipe_audit($ctx, $req);
  return Iczelia::HTTP::redirect('/admin/backup/?msg=wiped');
}

# CSRF, three checkboxes, the literal phrase, and the admin password.
# Returns a redirect / error response on failure, undef on success.
sub _wipe_validate_request {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'backup:wipe');
  return $err if $err;
  my $p = $req->{params};
  my @missing;
  push @missing, 'confirm1' unless $p->{confirm1};
  push @missing, 'confirm2' unless $p->{confirm2};
  push @missing, 'confirm3' unless $p->{confirm3};
  push @missing, 'phrase'   unless ($p->{phrase} // '') eq 'WIPE THIS SITE';
  my $auth_row = $ctx->db
    ->row('SELECT pwhash FROM auth WHERE username=?', $req->{auth_user});
  if (!$auth_row
    || !$ctx->auth->verify_password($p->{password} // '', $auth_row->{pwhash}))
  {
    push @missing, 'password';
  }
  return undef unless @missing;
  my $why = 'failed: ' . join(',', @missing);
  return Iczelia::HTTP::redirect('/admin/backup/?msg=' . escape_url($why));
}

# Drop every non-system table, reapply schema + seed, rehydrate auth.
# Returns undef on success or an error string.
sub _wipe_apply_schema {
  my ($ctx, $share, $auth_dump) = @_;
  my $ok = eval {
    $ctx->db->tx_immediate(
      sub {
        my $d      = shift;
        my $tables = $d->col(
          q{SELECT name FROM sqlite_master
                   WHERE type='table' AND name NOT LIKE 'sqlite_%'}
        );
        for my $t (@$tables) {

          # Plain ASCII only so an oddly-named table can't desync.
          next unless $t =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;
          $d->dbh->do(qq{DROP TABLE IF EXISTS "$t"});
        }
        $d->apply_schema_file("$share/schema.sql");
        $d->apply_schema_file("$share/seed.sql") if -f "$share/seed.sql";
        for my $a (@$auth_dump) {
          $d->do_(
            q{INSERT INTO auth(username, pwhash) VALUES(?, ?)
                ON CONFLICT(username) DO UPDATE SET pwhash=excluded.pwhash},
            $a->{username}, $a->{pwhash}
          );
        }
      }
    );
    1;
  };
  return $ok ? undef : ($@ || 'unknown error');
}

# Audit trail row. Best-effort; failure is swallowed.
sub _wipe_audit {
  my ($ctx, $req) = @_;
  eval {
    $ctx->db->do_(
      q{INSERT INTO analytics_events(ts, path, status, method,
            visitor_hash, referer_host, ua_class)
        VALUES(strftime('%s','now'), '/admin/wipe/', 200, 'POST',
               ?, NULL, 'browser')},
      substr(sha256_hex($req->{auth_user} . '|wipe'), 0, 16)
    );
  };
}

sub _date_stamp {
  my @t = gmtime(time);
  return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

sub _iso_date {
  my @t = gmtime(time);
  return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
    $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

sub _copy_file {
  my ($src, $dst) = @_;
  open my $in,  '<:raw', $src or die "open $src: $!";
  open my $out, '>:raw', $dst or die "open $dst: $!";
  my $buf;
  while (my $n = sysread($in, $buf, 65536)) {
    syswrite($out, $buf, $n);
  }
  close $in;
  close $out;
}

sub _sha256_file {
  my ($path) = @_;
  open my $fh, '<:raw', $path or return '';
  my $sha = Digest::SHA->new(256);
  $sha->addfile($fh);
  close $fh;
  return $sha->hexdigest;
}

1;
