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

package Iczelia::Handlers::Admin::Cache;
use strict;
use warnings;
use FindBin       ();
use File::Spec    ();
use JSON::PP      ();
use Iczelia::HTTP ();

use constant REBUILD_KEYS =>
  qw(phase scope total done started_at finished_at error pid);

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = sub {
    my $fn = shift;
    sub {$ctx->{auth}->gate($fn, $ctx, $_[0])}
  };
  $router->post('/admin/cache/drop',           $gate->(\&_cache_drop));
  $router->post('/admin/cache/rebuild',        $gate->(\&_cache_rebuild));
  $router->post('/admin/cache/rebuild/cancel', $gate->(\&_cache_rebuild_cancel));
  $router->get('/admin/cache/rebuild/status',  $gate->(\&_cache_rebuild_status));
}

# Public, exposed so {bin/iczelia-rebuild-cache,t/47*,t/48*} can import it.
sub run_rebuild {_run_rebuild(@_)}

# Public, exposed for the dashboard handler which inlines current
# rebuild state into the template.
sub rebuild_state {_rebuild_state(@_)}

sub _cache_drop {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'cache:drop');
  return $err if $err;
  my $db = $ctx->{db};
  $db->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM response_cache');
      $d->do_('DELETE FROM tex_cache');
      $d->do_('UPDATE pages SET rendered_html = NULL');
      $d->do_('UPDATE posts SET rendered_html = NULL');
      $d->do_('DELETE FROM settings WHERE key=?', 'math.cache_stats');
    }
  );
  return Iczelia::HTTP::redirect('/admin/?msg=cache-dropped');
}

# Kicks off bin/iczelia-rebuild-cache via fork+exec. Inline fork would
# inherit the request worker's open DBD::SQLite handle and abort the
# child on the first sqlite3_open (libsqlite is not fork-safe); exec
# wipes the inherited state.
sub _cache_rebuild {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'cache:rebuild');
  return $err if $err;
  require POSIX;

  my $scope = ($req->{params}{scope} // '') eq 'html' ? 'html' : 'all';

  my $db   = $ctx->{db};
  my $busy = _rebuild_state($db);
  if ($busy->{phase} =~ /^(?:starting|math|html|cancelling)$/) {
    return Iczelia::HTTP::redirect('/admin/?rebuilding=1');
  }

  $db->set_setting('cache.rebuild.phase',       'starting');
  $db->set_setting('cache.rebuild.scope',       $scope);
  $db->set_setting('cache.rebuild.total',       0);
  $db->set_setting('cache.rebuild.done',        0);
  $db->set_setting('cache.rebuild.started_at',  time());
  $db->set_setting('cache.rebuild.finished_at', 0);
  $db->set_setting('cache.rebuild.error',       '');
  $db->set_setting('cache.rebuild.pid',         0);

  my $cfg         = $ctx->{cfg};
  my $config_path = $cfg->{_config_path};
  if (!$config_path || !-r $config_path) {
    $db->set_setting('cache.rebuild.phase', 'error');
    $db->set_setting('cache.rebuild.error',
      'rebuild requires --config; daemon was started without one');
    $db->set_setting('cache.rebuild.finished_at', time());
    return Iczelia::HTTP::redirect('/admin/');
  }

  my $rebuild_bin = _rebuild_bin_path();
  if (!-x $rebuild_bin) {
    $db->set_setting('cache.rebuild.phase', 'error');
    $db->set_setting('cache.rebuild.error', "missing helper: $rebuild_bin");
    $db->set_setting('cache.rebuild.finished_at', time());
    return Iczelia::HTTP::redirect('/admin/');
  }

  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid != 0) {
    waitpid($pid, 0);
    return Iczelia::HTTP::redirect('/admin/?rebuilding=1');
  }

  POSIX::setsid();
  my $pid2 = fork();
  POSIX::_exit(0) if !defined $pid2 || $pid2 != 0;

  open STDIN,  '<',  '/dev/null';
  open STDOUT, '>>', '/dev/null';
  open STDERR, '>>', '/dev/null';
  for my $fd (3 .. 255) {eval {POSIX::close($fd)}}

  {exec($^X, $rebuild_bin, '--config', $config_path)}
  POSIX::_exit(127);
}

sub _rebuild_bin_path {
  return File::Spec->catfile($FindBin::RealBin, 'iczelia-rebuild-cache');
}

sub _cache_rebuild_cancel {
  my ($ctx, $req) = @_;
  my $err = $ctx->{auth}->require_csrf($req, 'cache:rebuild-cancel');
  return $err if $err;
  my $db    = $ctx->{db};
  my $state = _rebuild_state($db);
  if ($state->{phase} !~ /^(?:starting|math|html|cancelling)$/) {
    return Iczelia::HTTP::redirect('/admin/');
  }
  my $pid   = $state->{pid} || 0;
  my $alive = $pid > 0 && kill(0, $pid);

  if (!$alive) {
    _force_clear_rebuild($db);
  }
  elsif ($state->{phase} eq 'cancelling') {
    kill 'KILL', -$pid;
    _force_clear_rebuild($db);
  }
  else {
    kill 'TERM', -$pid;
    $db->set_setting('cache.rebuild.phase', 'cancelling');
  }
  return Iczelia::HTTP::redirect('/admin/');
}

sub _force_clear_rebuild {
  my ($db) = @_;
  $db->set_setting('cache.rebuild.phase',       'cancelled');
  $db->set_setting('cache.rebuild.finished_at', time());
  $db->set_setting('cache.rebuild.pid',         0);
}

sub _rebuild_state {
  my ($db) = @_;
  my %s;
  for my $k (REBUILD_KEYS) {
    $s{$k} = $db->setting("cache.rebuild.$k");
  }
  $s{$_} = ($s{$_} || 0) + 0 for qw(total done started_at finished_at pid);
  $s{phase} //= 'idle';
  $s{scope} //= 'all';
  $s{error} //= '';
  return \%s;
}

sub _cache_rebuild_status {
  my ($ctx, $req) = @_;
  my $s = _rebuild_state($ctx->{db});
  return {
    status    => 200,
    headers   => {'Content-Type' => 'application/json; charset=utf-8'},
    body      => JSON::PP::encode_json($s),
    _no_cache => 1,
  };
}

sub _run_rebuild {
  my ($cfg) = @_;
  require Time::HiRes;
  require Iczelia::Util;
  require Iczelia::DB;
  require Iczelia::Template;
  require Iczelia::Tex;
  require Iczelia::Cache;
  require Iczelia::Render;
  require Iczelia::Warmer;

  my $db    = Iczelia::DB->connect($cfg);
  my $scope = $db->setting('cache.rebuild.scope') // 'all';

  $db->do_('DELETE FROM response_cache');
  $db->do_('DELETE FROM tex_cache') if $scope eq 'all';
  $db->do_('UPDATE pages SET rendered_html = NULL');
  $db->do_('UPDATE posts SET rendered_html = NULL');
  $db->do_('DELETE FROM settings WHERE key=?', 'math.cache_stats')
    if $scope eq 'all';

  if ($scope eq 'all') {
    $db->set_setting('cache.rebuild.phase', 'math');
    $db->set_setting('cache.rebuild.total', 0);
    $db->set_setting('cache.rebuild.done',  0);
    $db->disconnect;
    eval {
      Iczelia::Warmer->new(cfg => $cfg)->warmup(
        progress_key => 'cache.rebuild.done',
        total_key    => 'cache.rebuild.total',
      );
    };
    $db = Iczelia::DB->connect($cfg);
  }
  my $pages = $db->col('SELECT slug FROM pages WHERE slug <> ?', 'home');
  my $posts = $db->all(
    q{SELECT kind, slug FROM posts
        WHERE draft=0
          AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))}
  );
  my @tasks = map {['page', $_]} @$pages;
  push @tasks, map {['post', $_->{kind}, $_->{slug}]} @$posts;
  my $total = scalar @tasks;

  $db->set_setting('cache.rebuild.phase', 'html');
  $db->set_setting('cache.rebuild.total', $total);
  $db->set_setting('cache.rebuild.done',  0);
  $db->disconnect;

  if ($total) {
    require POSIX;
    my $n = Iczelia::Util::detect_cores();
    $n = $total if $n > $total;
    $n ||= 1;
    my @pids;
    for my $w (0 .. $n - 1) {
      my $pid = fork();
      next unless defined $pid;
      if ($pid == 0) {
        $SIG{TERM} = sub {POSIX::_exit(0)};
        $SIG{INT}  = sub {POSIX::_exit(0)};
        my $cdb = Iczelia::DB->connect($cfg);
        my $tpl = Iczelia::Template->new(
          dirs => [$cfg->{'share-dir'} . '/templates']);
        my $ctex = Iczelia::Tex->new(
          db      => $cdb,
          tmp_dir => $cfg->{'tmp-dir'}
        );
        my $ccache = Iczelia::Cache->new(
          db      => $cdb,
          tmp_dir => $cfg->{'tmp-dir'}
        );
        my $crnd = Iczelia::Render->new(
          db       => $cdb,
          template => $tpl,
          tex      => $ctex,
          cache    => $ccache,
          cfg      => $cfg,
        );
        for (my $i = $w; $i < $total; $i += $n) {
          my $t = $tasks[$i];
          eval {
            if    ($t->[0] eq 'page') {$crnd->render_page($t->[1])}
            elsif ($t->[0] eq 'post') {$crnd->render_post($t->[1], $t->[2])}
          };
          $cdb->do_(
            'UPDATE settings SET value = CAST(value AS INTEGER) + 1
                 WHERE key = ?', 'cache.rebuild.done'
          );
        }
        $cdb->disconnect;
        POSIX::_exit(0);
      }
      push @pids, $pid;
    }
    waitpid($_, 0) for @pids;
  }

  $db = Iczelia::DB->connect($cfg);
  $db->set_setting('cache.rebuild.phase',       'done');
  $db->set_setting('cache.rebuild.finished_at', time());
  $db->set_setting('cache.rebuild.pid',         0);
  $db->disconnect;
}

1;
