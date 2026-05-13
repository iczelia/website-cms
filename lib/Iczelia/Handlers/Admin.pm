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

package Iczelia::Handlers::Admin;
use strict;
use warnings;
use Iczelia::HTTP                       ();
use Iczelia::Time                       qw(ts_fmt);
use Iczelia::Warmer                     ();
use Iczelia::Handlers::Admin::Activity  ();
use Iczelia::Handlers::Admin::Cache     ();
use Iczelia::Handlers::Admin::Dynamic   ();
use Iczelia::Handlers::Admin::Highlight ();
use Iczelia::Handlers::Admin::Media     ();
use Iczelia::Handlers::Admin::Pages     ();
use Iczelia::Handlers::Admin::PGP       ();
use Iczelia::Handlers::Admin::Posts     ();
use Iczelia::Handlers::Admin::Series    ();
use Iczelia::Handlers::Admin::Settings  ();
use Iczelia::Handlers::Admin::Webring   ();

use constant DASHBOARD_POSTS_LIMIT => 50;

sub register {
  my ($class, $router, $ctx) = @_;

  $router->get('/admin/',      sub {gate(\&_dashboard, $ctx, $_[0])});
  $router->get('/admin/login', sub {_login_form($ctx, $_[0])});
  $router->post('/admin/login',  sub {_login_submit($ctx, $_[0])});
  $router->post('/admin/logout', sub {_logout($ctx, $_[0])});

  Iczelia::Handlers::Admin::Pages->register($router, $ctx);
  Iczelia::Handlers::Admin::Posts->register($router, $ctx);
  Iczelia::Handlers::Admin::Series->register($router, $ctx);

  Iczelia::Handlers::Admin::Activity->register($router, $ctx);

  Iczelia::Handlers::Admin::Webring->register($router, $ctx);

  Iczelia::Handlers::Admin::Settings->register($router, $ctx);

  Iczelia::Handlers::Admin::Media->register($router, $ctx);
  Iczelia::Handlers::Admin::PGP->register($router, $ctx);

  Iczelia::Handlers::Admin::Cache->register($router, $ctx);
  $router->post('/admin/search/rebuild',
    sub {gate(\&_search_rebuild, $ctx, $_[0])});

  Iczelia::Handlers::Admin::Dynamic->register($router, $ctx);
  Iczelia::Handlers::Admin::Highlight->register($router, $ctx);
}

# Public so Backup / Guestbook / Analytics can hang their admin routes
# off the same gate without reaching for private symbols.
sub gate {my ($fn, $ctx, @r) = @_; $ctx->auth->gate($fn, $ctx, @r)}

sub _csrf_or_400 {
  my ($ctx, $req, $form) = @_;
  $ctx->auth->require_csrf($req, $form);
}

sub render_admin {
  my ($ctx, $req, $tpl, %extra) = @_;
  return Iczelia::HTTP::html(
    $ctx->template->render("views/$tpl", admin_vars($ctx, $req, %extra))
  );
}

sub admin_vars {
  my ($ctx, $req, %extra) = @_;
  my $sid     = $req->{auth_sid};
  my $pending = $ctx->db->one(
    q{SELECT COUNT(*) FROM guestbook_entries
          WHERE approved_at IS NULL AND rejected_at IS NULL}
  );

  # csrf_form: single-form views' scalar token.
  # csrf_extra: multi-form views' hashref of named tokens to merge.
  my $csrf_form  = delete $extra{csrf_form} // '';
  my $csrf_extra = delete $extra{csrf_extra} || {};

  my $csrf_hash = {
    logout               => $ctx->auth->csrf_token($sid, 'logout'),
    upload               => $ctx->auth->csrf_token($sid, 'upload'),
    preview              => $ctx->auth->csrf_token($sid, 'preview'),
    cache_drop           => $ctx->auth->csrf_token($sid, 'cache:drop'),
    cache_rebuild        => $ctx->auth->csrf_token($sid, 'cache:rebuild'),
    cache_rebuild_cancel =>
      $ctx->auth->csrf_token($sid, 'cache:rebuild-cancel'),
    %$csrf_extra,
  };
  return {
    title         => $extra{title}     || 'cms',
    version       => $Iczelia::VERSION || '0.1',
    csrf          => $csrf_hash,
    csrf_form     => $csrf_form,
    pending_count => $pending,
    flash         => $extra{flash},
    %extra,
  };
}

sub _login_form {
  my ($ctx, $req) = @_;
  my ($u) = $ctx->auth->current_user($req);
  return Iczelia::HTTP::redirect('/admin/') if $u;

  my ($cookie_value, $set) =
    $ctx->auth->anon_csrf_cookie($req->{cookies}{iczelia_csrf});
  my $token = $ctx->auth->anon_csrf_token($cookie_value, 'login');

  my $err = $req->{qparams}{e} // '';
  my $msg =
      $err eq 'bad' ? 'invalid credentials'
    : $err eq 'thr' ? 'too many attempts; try later'
    : $err eq 'err' ? 'something went wrong'
    :                 undef;
  my $html = $ctx->template->render(
    'views/admin_login.tpl',
    {
      title => 'login',
      csrf  => $token,
      error => $msg,
    }
  );

  # Like the guestbook form, this embeds a per-visitor anti-CSRF token
  # bound to the iczelia_csrf cookie and is served to logged-out
  # clients (so the nginx edge cache, which only bypasses on
  # iczelia_sid, would happily cache and reshare it). Keep it out of
  # every cache layer.
  my $resp = Iczelia::HTTP::html($html,
    headers => {'Cache-Control' => 'no-store'});
  $resp->{_no_cache} = 1;

  if ($set) {
    $resp->{cookies} = [
      Iczelia::HTTP::make_cookie(
        name     => 'iczelia_csrf',
        value    => $cookie_value,
        path     => '/',
        httponly => 1,
        samesite => 'Lax',
        secure   => Iczelia::HTTP::is_https($req),
      )
    ];
  }
  return $resp;
}

sub _login_submit {
  my ($ctx, $req) = @_;
  my $params = $req->{params};
  my $cookie = $req->{cookies}{iczelia_csrf} // '';
  my $token  = $params->{csrf}               // '';
  return Iczelia::HTTP::error(400, 'csrf')
    unless $ctx->auth->verify_anon_csrf($cookie, 'login', $token);

  my ($sid, $err) = $ctx->auth->login(
    $params->{username} // '',
    $params->{password} // '',
    $req->{remote} || '?'
  );
  if (defined $err) {
    my $code =
        $err eq 'throttled'       ? 'thr'
      : $err eq 'bad_credentials' ? 'bad'
      :                             'err';
    return Iczelia::HTTP::redirect("/admin/login?e=$code");
  }
  my $resp = Iczelia::HTTP::redirect('/admin/');
  $resp->{cookies} = [$ctx->auth->session_cookie($sid, $req)];
  return $resp;
}

sub _logout {
  my ($ctx, $req) = @_;
  my ($u,   $sid) = $ctx->auth->current_user($req);
  if ($u) {
    my $expected = $ctx->auth->csrf_token($sid, 'logout');
    if (($req->{params}{csrf} // '') eq $expected) {
      $ctx->auth->logout($sid);
    }
  }
  my $resp = Iczelia::HTTP::redirect('/admin/login');
  $resp->{cookies} = [$ctx->auth->session_cookie('', $req)];
  return $resp;
}

sub _dashboard {
  my ($ctx, $req) = @_;
  my $db = $ctx->db;
  my ($pages, $blog, $journal) = _dashboard_lists($db);
  return render_admin(
    $ctx, $req, 'admin_dashboard.tpl',
    title      => 'dashboard',
    pages      => $pages,
    blog       => $blog,
    journal    => $journal,
    math       => _dashboard_math_stats($db),
    rebuild    => _dashboard_rebuild_state($db),
    flash      => _dashboard_flash($req),
    csrf_extra => {
      search_rebuild =>
        $ctx->auth->csrf_token($req->{auth_sid}, 'search:rebuild'),
    },
  );
}

sub _dashboard_lists {
  my ($db)  = @_;
  my $pages = $db->all(
    q{SELECT slug, title, updated_at FROM pages ORDER BY slug});
  $_->{updated_fmt} = ts_fmt($_->{updated_at}) for @$pages;
  my $blog = $db->all(
    q{SELECT slug, title, date, draft FROM posts
        WHERE kind='blog'
        ORDER BY date DESC, created_at DESC, id DESC LIMIT } . DASHBOARD_POSTS_LIMIT
  );
  my $journal = $db->all(
    q{SELECT slug, title, date, draft FROM posts
        WHERE kind='journal'
        ORDER BY date DESC, created_at DESC, id DESC LIMIT } . DASHBOARD_POSTS_LIMIT
  );
  return ($pages, $blog, $journal);
}

# Reads the snapshot the background warmer maintains; never walks post
# bodies. See Warmer::stats / Warmer::_pass.
sub _dashboard_math_stats {
  my ($db)   = @_;
  my $math   = eval {Iczelia::Warmer->stats($db)}
    || {total => 0, cached => 0, missing => 0, cache_rows => 0};
  $math->{pct} =
    $math->{total}
    ? int($math->{cached} * 100 / $math->{total})
    : 100;
  return $math;
}

# Returns the current rebuild state hash, with stale-PID and expired-
# completion states normalised to undef so the template treats them as
# "nothing in flight".
sub _dashboard_rebuild_state {
  my ($db)    = @_;
  my $rebuild = Iczelia::Handlers::Admin::Cache::rebuild_state($db);
  if ($rebuild->{phase} =~ /^(?:math|html|cancelling)$/
    && $rebuild->{pid} > 0
    && !kill(0, $rebuild->{pid}))
  {
    Iczelia::Handlers::Admin::Cache::force_clear_rebuild($db);
    $rebuild = Iczelia::Handlers::Admin::Cache::rebuild_state($db);
    $rebuild->{error} = 'rebuild process exited without updating state';
  }
  return undef if $rebuild->{phase} eq 'idle';
  return undef
    if $rebuild->{phase} =~ /^(?:done|error|cancelled)$/
    && $rebuild->{finished_at}
    && time() - $rebuild->{finished_at} > 30;
  return $rebuild;
}

my %FLASH_TEXT = (
  'cache-dropped'  => 'cache dropped - next visit pays a full re-render.',
  'cache-rebuilt'  => 'cache rebuild complete.',
  'search-rebuilt' => 'search index rebuilt.',
);

# Translate request qparams into the flash banner. Sanitises unknown
# msg= text so a bookmarked URL can't inject HTML.
sub _dashboard_flash {
  my ($req) = @_;
  return {kind => 'ok', text => 'cache rebuild started in the background.'}
    if $req->{qparams}{rebuilding};
  my $msg = $req->{qparams}{msg} // '';
  return {kind => 'ok', text => $FLASH_TEXT{$msg}} if $FLASH_TEXT{$msg};
  return undef unless length $msg;
  my $clean = substr($msg, 0, 80);
  $clean =~ s/[^\w\- ]//g;
  return length $clean ? {kind => 'ok', text => $clean} : undef;
}

# Force-rebuild the FTS5 index from posts. Useful after a manual sqlite
# edit, or to recover if the index ever drifts from the source rows.
sub _search_rebuild {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'search:rebuild');
  return $err if $err;
  eval {$ctx->db->do_(q{INSERT INTO posts_fts(posts_fts) VALUES('rebuild')})};
  return Iczelia::HTTP::redirect('/admin/?msg=search-rebuilt');
}

# Render an arbitrary <body> string inside the admin chrome (caller
# already supplied its own <form>). Used by ad-hoc admin pages.
1;
