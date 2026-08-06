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

package Iczelia::Handlers::Admin::Git;
use strict;
use warnings;
use File::Path  qw(make_path remove_tree);
use Fcntl       qw(:flock);
use Iczelia::HTTP     ();
use Iczelia::Git      ();
use Iczelia::Git::Mirrors ();
use Iczelia::Subpages ();
use Iczelia::Upload   ();
use Iczelia::Time     qw(ts_fmt);

use constant MIRROR_URL_ERROR =>
  'mirror url must be http://, https://, ssh:// or user@host:path';

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  $router->get('/admin/git/',                $gate->(\&_list));
  $router->post('/admin/git/new',            $gate->(\&_create));
  $router->get('/admin/git/:id/edit',        $gate->(\&_edit));
  $router->post('/admin/git/:id/meta',       $gate->(\&_meta));
  $router->post('/admin/git/:id/mirror',     $gate->(\&_mirror));
  $router->post('/admin/git/:id/pull-now',   $gate->(\&_pull_now));
  $router->post('/admin/git/:id/import-zip', $gate->(\&_import_zip));
  $router->post('/admin/git/:id/delete',     $gate->(\&_delete));
  $router->post('/admin/git/groups/new',        $gate->(\&_group_create));
  $router->post('/admin/git/groups/:id/save',   $gate->(\&_group_save));
  $router->post('/admin/git/groups/:id/delete', $gate->(\&_group_delete));
}

sub _var_dir {
  my ($ctx) = @_;
  my $tmp = $ctx->cfg->{'tmp-dir'};
  return $tmp if !defined $tmp;
  (my $var = $tmp) =~ s{/tmp/?\z}{};
  return $var;
}

sub _list {_render_list(@_)}

sub _render_list {
  my ($ctx, $req, %opt) = @_;
  my $sid  = $req->{auth_sid};
  my $rows = $ctx->db->all(
    q{SELECT r.id, r.slug, r.title, r.owner, r.mirror_url, r.last_pulled_at,
              r.last_pull_status, r.last_pull_error, r.head_sha, r.updated_at,
              r.group_id, g.name AS group_name
        FROM git_repos r LEFT JOIN git_groups g ON g.id = r.group_id
       ORDER BY r.slug}
  );
  for my $r (@$rows) {
    $r->{url}            = "/git/$r->{slug}/";
    $r->{updated_fmt}    = ts_fmt($r->{updated_at});
    $r->{pulled_fmt}     = $r->{last_pulled_at}
      ? ts_fmt($r->{last_pulled_at}) : '';
    $r->{head_short}     = $r->{head_sha} ? substr($r->{head_sha}, 0, 10) : '';
    $r->{csrf_del}       =
      $ctx->auth->csrf_token($sid, "gitrepo:del:$r->{id}");
  }

  my $groups = _groups($ctx->db);
  for my $g (@$groups) {
    $g->{repo_count} = $ctx->db->one(
      'SELECT COUNT(*) FROM git_repos WHERE group_id=?', $g->{id}) // 0;
    $g->{csrf_save} = $ctx->auth->csrf_token($sid, "gitgroup:save:$g->{id}");
    $g->{csrf_del}  = $ctx->auth->csrf_token($sid, "gitgroup:del:$g->{id}");
  }

  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_git_list.tpl',
    title          => 'git repositories',
    git_available  => (Iczelia::Git::available() ? 1 : 0),
    repos          => $rows,
    groups         => $groups,
    group_options  => _group_options($groups, $opt{group_id}),
    error          => $opt{error},
    notice         => $opt{notice},
    slug_value     => $opt{slug}        // '',
    title_value    => $opt{title}       // '',
    owner_value    => $opt{owner}       // '',
    desc_value     => $opt{description} // '',
    mirror_value   => $opt{mirror_url}  // '',
    interval_value => $opt{interval}    // '3600',
    csrf_form      => $ctx->auth->csrf_token($sid, 'gitrepo:new'),
    csrf_group     => $ctx->auth->csrf_token($sid, 'gitgroup:new'),
  );
}

sub _groups {
  my ($db) = @_;
  return $db->all(
    'SELECT id, name, position FROM git_groups ORDER BY position, name');
}

# <option> rows for the group picker. The empty entry is "ungrouped",
# which is also what a deleted group leaves behind.
sub _group_options {
  my ($groups, $selected) = @_;
  $selected = 0 unless defined $selected && $selected =~ /^\d+$/;
  my @out = {id => '', name => '(ungrouped)', selected => ($selected ? 0 : 1)};
  push @out, {
    id       => $_->{id},
    name     => $_->{name},
    selected => ($_->{id} == $selected ? 1 : 0),
  } for @$groups;
  return \@out;
}

sub _group_create {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'gitgroup:new');
  return $err if $err;
  my $name = _trim($req->{params}{name});
  return _render_list($ctx, $req, error => 'group name required')
    unless defined $name && length $name;
  return _render_list($ctx, $req, error => 'group name too long')
    if length($name) > 120;
  return _render_list($ctx, $req, error => "group '$name' already exists")
    if $ctx->db->row('SELECT 1 FROM git_groups WHERE name=?', $name);

  my $now = time;
  $ctx->db->do_(
    q{INSERT INTO git_groups(name, position, created_at, updated_at)
        VALUES(?,?,?,?)},
    $name, _norm_pos($req->{params}{position}), $now, $now
  );
  _bust($ctx);
  return _render_list($ctx, $req, notice => "group '$name' created.");
}

sub _group_save {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $g  = $ctx->db->row('SELECT * FROM git_groups WHERE id=?', $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "gitgroup:save:$id");
  return $err if $err;

  my $name = _trim($req->{params}{name});
  return _render_list($ctx, $req, error => 'group name required')
    unless defined $name && length $name;
  return _render_list($ctx, $req, error => 'group name too long')
    if length($name) > 120;
  my $clash = $ctx->db->row('SELECT id FROM git_groups WHERE name=?', $name);
  return _render_list($ctx, $req, error => "group '$name' already exists")
    if $clash && $clash->{id} != $id;

  $ctx->db->do_(
    'UPDATE git_groups SET name=?, position=?, updated_at=? WHERE id=?',
    $name, _norm_pos($req->{params}{position}), time, $id
  );
  _bust($ctx);
  return _render_list($ctx, $req, notice => 'group saved.');
}

sub _group_delete {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $g  = $ctx->db->row('SELECT * FROM git_groups WHERE id=?', $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "gitgroup:del:$id");
  return $err if $err;

  # Upgraded databases carry group_id without the REFERENCES clause, so
  # the detach is done here rather than left to ON DELETE SET NULL.
  $ctx->db->tx(
    sub {
      my $d = shift;
      $d->do_('UPDATE git_repos SET group_id=NULL WHERE group_id=?', $id);
      $d->do_('DELETE FROM git_groups WHERE id=?', $id);
    }
  );
  _bust($ctx);
  return _render_list($ctx, $req,
    notice => "group '$g->{name}' deleted; its repositories are now ungrouped.");
}

# Validate a group id against the table. Returns undef for "ungrouped"
# and for an id that no longer exists.
sub _norm_group_id {
  my ($ctx, $v) = @_;
  return undef unless defined $v && $v =~ /^(\d+)$/ && $1 > 0;
  return $ctx->db->row('SELECT 1 FROM git_groups WHERE id=?', $1) ? $1 + 0 : undef;
}

sub _norm_pos {
  my ($v) = @_;
  return 0 unless defined $v && $v =~ /^(-?\d+)$/;
  my $n = $1 + 0;
  $n = -9999 if $n < -9999;
  $n = 9999  if $n > 9999;
  return $n;
}

sub _create {
  my ($ctx, $req) = @_;
  my $err = $ctx->auth->require_csrf($req, 'gitrepo:new');
  return $err if $err;
  return _render_list($ctx, $req, error => 'git backend not available')
    unless Iczelia::Git::available();

  my $slug  = _norm_slug($req->{params}{slug});
  my $title = $req->{params}{title}       // '';
  my $owner = $req->{params}{owner}       // '';
  my $desc  = $req->{params}{description} // '';
  my $murl  = _trim($req->{params}{mirror_url});
  my $iv    = _norm_int($req->{params}{mirror_interval_s}, 3600);
  my $gid   = _norm_group_id($ctx, $req->{params}{group_id});

  my @form = (
    slug => $slug, title => $title, owner => $owner,
    description => $desc, mirror_url => $murl, interval => $iv,
    group_id => $gid,
  );

  return _render_list($ctx, $req, @form,
    error => 'invalid slug: use a-z, 0-9 and dashes, avoid reserved names')
    unless Iczelia::Subpages::valid_slug($slug);
  return _render_list($ctx, $req, @form,
    error => "the slug '$slug' is already in use")
    if _slug_taken($ctx, $slug, 0);

  if (defined $murl && length $murl
    && !Iczelia::Git::valid_mirror_url($murl))
  {
    return _render_list($ctx, $req, @form, error => MIRROR_URL_ERROR);
  }

  my $var = _var_dir($ctx);
  my $path = eval { Iczelia::Git::bare_repo_path($var, $slug) };
  return _render_list($ctx, $req, @form, error => "bad slug path: $@")
    unless defined $path;

  my $now = time;
  my ($zip_data, $zip_err) = _zip_bytes_from_req($ctx, $req);
  return _render_list($ctx, $req, @form, error => $zip_err) if $zip_err;

  # Initialise the bare repo first; mirror config can be set without a
  # clone (the warmer will pick it up next pass) and an import-zip
  # commit lands directly. If a mirror URL was provided we DO NOT
  # init+commit -- we let the warmer clone --mirror so the upstream
  # refs structure is preserved.
  my $id;
  eval {
    if (defined $murl && length $murl) {
      # Mirror mode: defer clone to warmer. Just stamp the DB row.
      $id = _insert_repo(
        $ctx->db, $slug, $title, $owner, $desc, $murl, $iv, $now, undef, $gid
      );
      1;
    }
    else {
      # Owned mode: init bare repo, optionally import zip as first commit.
      Iczelia::Git::init_bare($path);
      if (defined $zip_data) {
        my ($files, $zerr) = Iczelia::Subpages::extract_zip($zip_data);
        die "zip: $zerr\n" if $zerr;
        my $author_name  = _trim($req->{params}{author_name})  // 'iczelia';
        my $author_email = _trim($req->{params}{author_email})
          // ($ctx->db->setting('site.email') // 'noreply@iczelia.net');
        my $msg = _trim($req->{params}{commit_message}) // 'initial import';
        Iczelia::Git::import_zip(
          $path, $files,
          author_name  => $author_name,
          author_email => $author_email,
          message      => $msg,
        );
      }
      my $head = eval { Iczelia::Git::head_sha(Iczelia::Git::open_bare($path)) };
      $id = _insert_repo(
        $ctx->db, $slug, $title, $owner, $desc, undef, $iv, $now, $head, $gid
      );
      1;
    }
  } or do {
    my $e = $@ || 'unknown error';
    $e =~ s/\s+\z//;
    eval { remove_tree($path) };
    return _render_list($ctx, $req, @form, error => "create: $e");
  };

  _bust($ctx, $slug);
  return Iczelia::HTTP::redirect("/admin/git/$id/edit");
}

sub _insert_repo {
  my ($db, $slug, $title, $owner, $desc, $murl, $iv, $now, $head, $gid) = @_;
  $db->do_(
    q{INSERT INTO git_repos
        (slug, title, owner, description, mirror_url, mirror_interval_s,
         head_sha, group_id, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?)},
    $slug, $title // '', $owner // '', $desc // '',
    $murl, $iv, $head, $gid, $now, $now
  );
  return $db->last_id;
}

sub _edit {_render_edit(@_)}

sub _render_edit {
  my ($ctx, $req, %opt) = @_;
  my $id  = _id($req);
  my $sid = $req->{auth_sid};
  my $row = $ctx->db->row('SELECT * FROM git_repos WHERE id=?', $id)
    or return Iczelia::HTTP::error(404);
  $row->{updated_fmt} = ts_fmt($row->{updated_at});
  $row->{pulled_fmt}  = $row->{last_pulled_at}
    ? ts_fmt($row->{last_pulled_at}) : '';
  $row->{head_short}  = $row->{head_sha} ? substr($row->{head_sha}, 0, 10) : '';

  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_git_edit.tpl',
    title => "git: $row->{slug}",
    repo  => $row,
    group_options => _group_options(_groups($ctx->db), $row->{group_id}),
    git_available => (Iczelia::Git::available() ? 1 : 0),
    error  => $opt{error},
    notice => $opt{notice},
    csrf_extra => {
      meta   => $ctx->auth->csrf_token($sid, "gitrepo:meta:$id"),
      mirror => $ctx->auth->csrf_token($sid, "gitrepo:mirror:$id"),
      pull   => $ctx->auth->csrf_token($sid, "gitrepo:pull:$id"),
      import => $ctx->auth->csrf_token($sid, "gitrepo:import:$id"),
      del    => $ctx->auth->csrf_token($sid, "gitrepo:del:$id"),
    },
  );
}

sub _meta {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $row = $ctx->db->row('SELECT slug FROM git_repos WHERE id=?', $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "gitrepo:meta:$id");
  return $err if $err;

  my $title = $req->{params}{title}          // '';
  my $owner = $req->{params}{owner}          // '';
  my $desc  = $req->{params}{description}    // '';
  my $br    = _trim($req->{params}{default_branch}) // 'main';
  my $gid   = _norm_group_id($ctx, $req->{params}{group_id});
  return _render_edit($ctx, $req, error => 'branch name looks bogus')
    unless $br =~ /^[A-Za-z0-9._\/-]+\z/;

  my $old  = $row->{slug};
  my $slug = _norm_slug($req->{params}{slug});
  $slug = $old unless length $slug;
  if ($slug ne $old) {
    return _render_edit($ctx, $req,
      error => 'invalid slug: use a-z, 0-9 and dashes, avoid reserved names')
      unless Iczelia::Subpages::valid_slug($slug);
    return _render_edit($ctx, $req,
      error => "the slug '$slug' is already in use")
      if _slug_taken($ctx, $slug, $id);
    if (my $rerr = _rename_bare($ctx, $old, $slug)) {
      return _render_edit($ctx, $req, error => $rerr);
    }
  }

  $ctx->db->do_(
    q{UPDATE git_repos SET slug=?, title=?, owner=?, description=?,
        default_branch=?, group_id=?, updated_at=? WHERE id=?},
    $slug, $title, $owner, $desc, $br, $gid, time, $id
  );
  _bust($ctx, $slug);
  _bust($ctx, $old) if $slug ne $old;
  return _render_edit($ctx, $req,
    notice => $slug eq $old
      ? 'saved.'
      : "saved; repository moved to /git/$slug/ (links to /git/$old/ now 404).");
}

# Move the on-disk bare repo to match a new slug. Returns an error
# string, or undef on success and when there is nothing to move (a
# mirror whose first clone has not run). The caller's DB write runs
# only after this succeeds.
sub _rename_bare {
  my ($ctx, $old, $new) = @_;
  my $var = _var_dir($ctx);
  my ($from, $to) =
    map { eval {Iczelia::Git::bare_repo_path($var, $_)} } $old, $new;
  return "bad slug path: $@" unless defined $from && defined $to;
  return undef unless -e $from;
  return "a bare repo already exists at $to" if -e $to;
  rename($from, $to) or return "rename: $!";
  unlink "$var/git/$old.lock";
  return undef;
}

sub _mirror {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $row = $ctx->db->row('SELECT slug FROM git_repos WHERE id=?', $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "gitrepo:mirror:$id");
  return $err if $err;

  my $murl = _trim($req->{params}{mirror_url});
  my $iv   = _norm_int($req->{params}{mirror_interval_s}, 3600);
  if (defined $murl && length $murl
    && !Iczelia::Git::valid_mirror_url($murl))
  {
    return _render_edit($ctx, $req, error => MIRROR_URL_ERROR);
  }
  $murl = undef unless defined $murl && length $murl;
  $ctx->db->do_(
    q{UPDATE git_repos SET mirror_url=?, mirror_interval_s=?, updated_at=?
        WHERE id=?}, $murl, $iv, time, $id
  );
  _bust($ctx, $row->{slug});
  return _render_edit($ctx, $req, notice => 'mirror settings saved.');
}

sub _pull_now {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $row =
    $ctx->db->row('SELECT * FROM git_repos WHERE id=?', $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "gitrepo:pull:$id");
  return $err if $err;
  return _render_edit($ctx, $req, error => 'git backend not available')
    unless Iczelia::Git::available();
  return _render_edit($ctx, $req, error => 'no mirror url configured')
    unless defined $row->{mirror_url} && length $row->{mirror_url};

  my $var  = _var_dir($ctx);
  my $path = Iczelia::Git::bare_repo_path($var, $row->{slug});
  make_path("$var/git");
  my $lockfile = "$var/git/$row->{slug}.lock";
  open my $lock, '>', $lockfile
    or return _render_edit($ctx, $req, error => "lock: $!");
  unless (flock($lock, LOCK_EX | LOCK_NB)) {
    close $lock;
    return _render_edit($ctx, $req, error => 'another pull is in progress');
  }

  my $ssh = Iczelia::Git::Mirrors::ssh_opts($ctx->cfg, $var);
  my ($ok, $perr, $new_head);
  if (-d "$path/objects") {
    ($ok, $perr, $new_head) = Iczelia::Git::pull_mirror($path, ssh => $ssh);
  }
  else {
    ($ok, $perr, $new_head) = eval {
      Iczelia::Git::clone_mirror($path, $row->{mirror_url}, ssh => $ssh);
    };
    $perr = $@ unless defined $ok;
  }
  flock($lock, LOCK_UN);
  close $lock;

  my $now = time;
  if ($ok) {
    $ctx->db->do_(
      q{UPDATE git_repos SET last_pulled_at=?, last_pull_status='ok',
          last_pull_error=NULL, head_sha=?, updated_at=? WHERE id=?},
      $now, $new_head, $now, $id
    );
    if (defined $new_head
      && (!defined $row->{head_sha} || $new_head ne $row->{head_sha}))
    {
      $ctx->db->do_(
        'DELETE FROM git_commit_cache WHERE repo_id=? AND head_sha!=?',
        $id, $new_head
      );
    }
    _bust($ctx, $row->{slug});
    return _render_edit($ctx, $req,
      notice => "pulled; head=" . ($new_head // 'none'));
  }
  my $emsg = (defined $perr ? "$perr" : 'unknown error');
  $emsg =~ s/\s+\z//;
  $ctx->db->do_(
    q{UPDATE git_repos SET last_pulled_at=?, last_pull_status='error',
        last_pull_error=?, updated_at=? WHERE id=?},
    $now, substr($emsg, 0, 1024), $now, $id
  );
  return _render_edit($ctx, $req, error => "pull failed: $emsg");
}

sub _import_zip {
  my ($ctx, $req) = @_;
  my $id = _id($req);
  my $row = $ctx->db->row('SELECT * FROM git_repos WHERE id=?', $id)
    or return Iczelia::HTTP::error(404);
  my $err = $ctx->auth->require_csrf($req, "gitrepo:import:$id");
  return $err if $err;
  return _render_edit($ctx, $req, error => 'git backend not available')
    unless Iczelia::Git::available();

  my ($zip_data, $zip_err) = _zip_bytes_from_req($ctx, $req);
  return _render_edit($ctx, $req, error => $zip_err) if $zip_err;
  return _render_edit($ctx, $req, error => 'attach a .zip bundle')
    unless defined $zip_data;
  my ($files, $zerr) = Iczelia::Subpages::extract_zip($zip_data,
    unlimited => 1);
  return _render_edit($ctx, $req, error => "zip: $zerr") if $zerr;

  my $var  = _var_dir($ctx);
  my $path = Iczelia::Git::bare_repo_path($var, $row->{slug});
  unless (-d "$path/objects") {
    eval { Iczelia::Git::init_bare($path) }
      or return _render_edit($ctx, $req, error => "init: $@");
  }
  my $branch = length($row->{default_branch})
    ? $row->{default_branch} : 'main';
  my $author = _trim($req->{params}{author_name}) // 'iczelia';
  my $email  = _trim($req->{params}{author_email})
    // ($ctx->db->setting('site.email') // 'noreply@iczelia.net');
  my $msg    = _trim($req->{params}{commit_message}) // 'overlay import';

  my ($ok, $ierr);
  eval {
    ($ok, $ierr) = Iczelia::Git::import_zip(
      $path, $files,
      branch       => $branch,
      author_name  => $author,
      author_email => $email,
      message      => $msg,
    );
    1;
  } or do { $ierr = $@ };
  if (!$ok) {
    my $e = $ierr || 'unknown';
    $e =~ s/\s+\z//;
    return _render_edit($ctx, $req, error => "import: $e");
  }
  my $new_head = eval {
    Iczelia::Git::head_sha(Iczelia::Git::open_bare($path));
  };
  $ctx->db->do_(
    q{UPDATE git_repos SET head_sha=?, updated_at=? WHERE id=?},
    $new_head, time, $id
  );
  $ctx->db->do_(
    'DELETE FROM git_commit_cache WHERE repo_id=? AND head_sha!=?',
    $id, $new_head // ''
  ) if $new_head;
  _bust($ctx, $row->{slug});
  return _render_edit($ctx, $req, notice => 'bundle imported.');
}

sub _delete {
  my ($ctx, $req) = @_;
  my $id  = _id($req);
  my $row = $ctx->db->row('SELECT slug FROM git_repos WHERE id=?', $id);
  my $err = $ctx->auth->require_csrf($req, "gitrepo:del:$id");
  return $err if $err;
  if ($row) {
    my $var  = _var_dir($ctx);
    my $path = eval { Iczelia::Git::bare_repo_path($var, $row->{slug}) };
    eval { remove_tree($path) } if defined $path;
    $ctx->db->do_('DELETE FROM git_repos WHERE id=?', $id);
    _bust($ctx, $row->{slug});
  }
  return Iczelia::HTTP::redirect('/admin/git/');
}

sub _bust {
  my ($ctx, $slug) = @_;
  eval {
    $ctx->cache->bust('/git/');
    $ctx->cache->bust_prefix("/git/$slug/") if defined $slug && length $slug;
    1;
  };
}

sub _id {
  my ($req) = @_;
  my $id = $req->{caps}{id};
  return (defined $id && $id =~ /^(\d+)$/) ? $1 + 0 : 0;
}

sub _norm_slug {
  my ($s) = @_;
  $s = '' unless defined $s;
  $s =~ s/^\s+//; $s =~ s/\s+$//;
  return lc $s;
}

sub _trim {
  my ($s) = @_;
  return undef unless defined $s;
  $s =~ s/^\s+//; $s =~ s/\s+$//;
  return $s;
}

sub _norm_int {
  my ($s, $default) = @_;
  return $default unless defined $s && $s =~ /^(\d+)$/;
  my $n = $1 + 0;
  $n = 60      if $n < 60;
  $n = 86_400 * 30 if $n > 86_400 * 30;
  return $n;
}

# Pulls bundle bytes from either the chunked upload (params.upload_id)
# or a classic multipart upload. Returns ($bytes, $error); both undef
# means "no file attached, fall through".
sub _zip_bytes_from_req {
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
    return ($data, undef);
  }
  my @up = @{$req->{uploads} || []};
  return ($up[0]{body}, undef)
    if @up && defined $up[0]{body} && length $up[0]{body};
  return (undef, undef);
}

sub _slug_taken {
  my ($ctx, $slug, $exclude_id) = @_;
  my $r = $ctx->db->row('SELECT id FROM git_repos WHERE slug=?', $slug);
  return 1 if $r && $r->{id} != ($exclude_id || 0);
  return 1
    if Iczelia::Subpages::get_by_slug($ctx->db, $slug);
  return 1
    if $ctx->db->row('SELECT 1 FROM dynamic_pages WHERE route=?', "/$slug/");
  return 0;
}

1;
