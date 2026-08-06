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
use Iczelia::HTTP      ();
use Iczelia::TarStream ();
use Iczelia::Upload    ();
use Iczelia::Util      qw(escape_url);
use File::Path         qw(make_path remove_tree);
use File::Spec         ();
use Digest::SHA        qw(sha256_hex);
use JSON::PP           ();
use DBI                ();
use Archive::Tar       ();

# Backup: VACUUM INTO snapshot, ephemeral tables stripped, tar with
# media/. Restore atomically swaps the live DB and media/ tree.

# Tables whose contents are tied to the running instance (cache,
# session, throttle counters) and are wiped from snapshots.
my @EPHEMERAL_TABLES = qw(
  response_cache tex_cache sessions login_throttle guestbook_throttle
);

my $JSON = JSON::PP->new->utf8(1)->canonical(1)->pretty(1);

# Strip instance-bound rows from a freshly VACUUM-INTO'd snapshot before
# it ships in a backup: the ephemeral tables (cache/session/throttle)
# and any auth secret lingering in settings. The session/CSRF secret is
# file-based and no longer read from the db, but old databases may still
# carry an auth.cookie_secret row, and key material must never ride along
# in an exported archive. Each delete is tolerant of a missing table.
sub _scrub_snapshot {
  my ($dbh) = @_;
  eval {$dbh->do("DELETE FROM $_")} for @EPHEMERAL_TABLES;
  eval {$dbh->do(q{DELETE FROM settings WHERE key = 'auth.cookie_secret'})};
}

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
    title      => 'backup / wipe',
    # csrf_extra (not csrf): these merge into the admin csrf hash so the
    # layout's own tokens -- notably csrf.upload, which the chunked
    # uploader reads from <meta name="cms-upload-csrf"> -- survive.
    csrf_extra => {
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

  # Build the snapshot DB up front (fast: VACUUM INTO + ephemeral
  # scrub). If this fails the handler returns 500 before any response
  # bytes are on the wire; once we start streaming we can't change
  # status anymore.
  my $snap = "$work/site.db";
  eval {
    $ctx->db->dbh->do(q{VACUUM INTO ?}, undef, $snap);
    my $tdb = DBI->connect("dbi:SQLite:dbname=$snap", '', '',
      {RaiseError => 1, PrintError => 0, AutoCommit => 1});
    _scrub_snapshot($tdb);
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

  # Streamed response: each tar entry hits the socket immediately so
  # the upstream (nginx in front of the daemon) keeps seeing bytes
  # and never trips its proxy_read_timeout, even on multi-GB media
  # libraries. Memory footprint stays bounded at one 64 KB chunk.
  return {
    status  => 200,
    headers => {
      'Content-Type'        => 'application/x-tar',
      'Content-Disposition' =>
        qq{attachment; filename="iczelia-backup-$stamp.tar"},
      'Cache-Control' => 'no-store',
    },
    _no_cache => 1,
    stream    => sub {
      my ($w) = @_;
      my $ts = Iczelia::TarStream->new(write => $w);
      eval {
        # site.db: stream from disk so a giant DB never lands in RAM.
        my $snap_size = -s $snap;
        if (defined $snap_size && open my $fh, '<:raw', $snap) {
          $ts->add_fh('site.db', $fh, $snap_size);
          close $fh;
        }
        $ts->add_data('MANIFEST.json', $manifest);
        for my $fn (@media_files) {
          my $path = "$media_src/$fn";
          my $size = -s $path;
          next unless defined $size;
          if (open my $fh, '<:raw', $path) {
            $ts->add_fh("media/$fn", $fh, $size);
            close $fh;
          }
        }
        $ts->finish;
        1;
      } or warn "backup export stream error: $@";
      remove_tree($work);
    },
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


sub _archive_problem {
  my ($tar_path) = @_;
  my $iter = eval {Archive::Tar->iter($tar_path)};
  return 'archive unreadable (corrupt or not a tar)' unless $iter;
  my $total = 0;
  while (my $entry = eval {$iter->()}) {
    my $name = $entry->full_path;
    return 'unsafe path in archive' unless defined $name && length $name;
    return 'unsafe path in archive'
      if $name =~ m{^/} || $name =~ m{(?:^|/)\.\.(?:/|$)};
    $total += $entry->size || 0;
  }
  return undef;
}

# Restore the live db from a validated snapshot WITHOUT swapping files.
sub _restore_from_snapshot {
  my ($db, $snap) = @_;

  my $tables = do {
    my $s = DBI->connect("dbi:SQLite:dbname=$snap", '', '',
      {RaiseError => 1, PrintError => 0});
    my $r = $s->selectcol_arrayref(
      q{SELECT name FROM sqlite_master WHERE type='table'
          AND name NOT LIKE 'sqlite_%' ORDER BY name});
    $s->disconnect;
    $r;
  };

  my $dbh = $db->dbh;
  $dbh->do('ATTACH DATABASE ? AS src', undef, $snap);
  my $ok = eval {
    $dbh->begin_work;
    $dbh->do('PRAGMA defer_foreign_keys = ON');
    for my $t (@$tables) {
      my @cols = _common_columns($dbh, $t);
      next unless @cols;
      my $list = join ',', map {qq{"$_"}} @cols;
      $dbh->do(qq{DELETE FROM main."$t"});
      $dbh->do(qq{INSERT INTO main."$t" ($list) SELECT $list FROM src."$t"});
    }
    $dbh->commit;
    1;
  };
  my $err = $@;
  unless ($ok) {
    unless (eval {$dbh->rollback; 1}) {
      warn "restore: rollback failed: $@";
      eval {$db->reconnect};    # drop the wedged write transaction
    }
  }
  eval {$dbh->do('DETACH DATABASE src')};
  die($err || "restore failed\n") unless $ok;
  return 1;
}

# Column names present in BOTH main.<t> and src.<t>, in main's order.
sub _common_columns {
  my ($dbh, $t) = @_;
  my $main = $dbh->selectall_arrayref(qq{PRAGMA main.table_info("$t")});
  my $src  = $dbh->selectall_arrayref(qq{PRAGMA src.table_info("$t")});
  my %in_src = map {$_->[1] => 1} @$src;
  return grep {$in_src{$_}} map {$_->[1]} @$main;
}

# Replace $dst's contents with $src's without a wipe-then-copy window:
# stage into a sibling dir on the same filesystem, then swap with two
# renames. On any failure $dst is left untouched. Returns undef on
# success, else an error string.
sub _swap_media_dir {
  my ($src, $dst) = @_;
  my $staging = "$dst.incoming.$$";
  my $old     = "$dst.old.$$";
  remove_tree($staging) if -e $staging;

  my $ok = eval {
    make_path($staging);
    if (opendir my $dh, $src) {
      for my $fn (readdir $dh) {
        next if $fn =~ /^\./ || $fn =~ m{[/\\]};
        _copy_file("$src/$fn", "$staging/$fn");
      }
      closedir $dh;
    }
    1;
  };
  unless ($ok) {
    my $e = $@ || 'copy failed';
    remove_tree($staging);
    return $e;
  }

  if (-e $dst) {
    rename($dst, $old) or do {remove_tree($staging); return "rename dst: $!"};
  }
  unless (rename($staging, $dst)) {
    my $e = "$!";
    rename($old, $dst) if -e $old;
    remove_tree($staging);
    return "rename staging: $e";
  }
  remove_tree($old) if -e $old;
  return undef;
}

sub _import {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'backup:import');
  return $err if $err;

  my $tmp_dir = $ctx->cfg->{'tmp-dir'} || '/tmp';
  make_path($tmp_dir) unless -d $tmp_dir;
  my $work = "$tmp_dir/iczelia-import.$$";
  make_path($work);
  my $tar_path = "$work/upload.tar";

  # Two entry paths:
  #   (a) classic multipart upload (small tarballs, JS off): the
  #       chunked uploader is the default, but if it's bypassed we
  #       still accept the full body in one POST.
  #   (b) chunked uploader: the JS pushes 2 MB slices to
  #       /admin/upload/chunk, then submits this form with an
  #       upload_id field. We claim the assembled file by reference
  #       so a 4 GB import never lands in $req->{uploads}.
  my $upload_id = $req->{params}{upload_id};
  my $upload    = Iczelia::Upload->new(db => $ctx->db, tmp_dir => $tmp_dir);
  my $assembled;
  if (defined $upload_id && length $upload_id) {
    $upload->finalize($upload_id, $req->{auth_sid});
    my ($path, $cerr) = $upload->claim($upload_id, $req->{auth_sid});
    if (!$path) {
      remove_tree($work);
      return Iczelia::HTTP::error(400, "upload: $cerr");
    }
    # Move the assembled chunk file into the work dir; the import
    # path expects $work/upload.tar. rename() is atomic on the same
    # filesystem (var/tmp), so no data copy.
    unless (rename($path, $tar_path)) {
      $upload->cleanup($upload_id, $req->{auth_sid});
      remove_tree($work);
      return Iczelia::HTTP::error(500, "stage upload: $!");
    }
    $upload->cleanup($upload_id, $req->{auth_sid});
    $assembled = 1;
  }
  else {
    my @files = @{$req->{uploads} || []};
    if (!@files) {
      remove_tree($work);
      return Iczelia::HTTP::error(400, 'no file');
    }
    my $f = $files[0];
    open my $fh, '>:raw', $tar_path
      or do {remove_tree($work); return Iczelia::HTTP::error(500, "write: $!")};
    print $fh $f->{body};
    close $fh;
  }

  if (my $why = _archive_problem($tar_path)) {
    remove_tree($work);
    return Iczelia::HTTP::error(400, $why);
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
    my ($integ) = $vdb->selectrow_array('PRAGMA integrity_check');
    die "snapshot integrity_check: $integ\n"
      unless defined $integ && $integ eq 'ok';
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

  # Snapshot the live db before overwriting its contents, so a regretted
  # or failed import is recoverable. Refuse to proceed if we can't.
  my $backup = $ctx->db->{path} . '.preimport-' . _date_stamp();
  unless (eval {$ctx->db->dbh->do('VACUUM INTO ?', undef, $backup); 1}) {
    my $berr = $@;
    remove_tree($work);
    return Iczelia::HTTP::error(500, "pre-import backup failed: $berr");
  }

  unless (eval {_restore_from_snapshot($ctx->db, $snap); 1}) {
    my $rerr = $@;
    remove_tree($work);
    return Iczelia::HTTP::error(500,
      "restore failed (live db unchanged): $rerr");
  }

  my $media_src = "$work/media";
  my $media_dst = $ctx->cfg->{'media-dir'};
  if ($media_dst && -d $media_src) {
    if (my $merr = _swap_media_dir($media_src, $media_dst)) {
      remove_tree($work);
      return Iczelia::HTTP::error(500,
        "db restored but media swap failed: $merr "
        . "(old media left intact; pre-import db backup at $backup)");
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
