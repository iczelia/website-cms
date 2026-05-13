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

package Iczelia::Handlers::Guestbook;
use strict;
use warnings;
use Iczelia::HTTP       ();
use Iczelia::Util       qw(escape_url decode_json_hash);
use Iczelia::Time       qw(ts_fmt);
use Iczelia::SafeMarkup ();
use Iczelia::Markup     ();
use Iczelia::Throttle;

use constant {
  GUESTBOOK_PUBLIC_ENTRIES_LIMIT => 200,
  GUESTBOOK_ADMIN_APPROVED_LIMIT => 50,
};

# Public submission + admin moderation. Admin routes are gated via
# Iczelia::Handlers::Admin::gate so they share the same auth chrome.

sub register {
  my ($class, $router, $ctx) = @_;

  $ctx->{gb_throttle_short} ||= Iczelia::Throttle->new(
    db     => $ctx->{db},
    table  => 'guestbook_throttle',
    max    => 1,
    window => 5 * 60,                 # 1 per IP per 5 min
  );
  $ctx->{gb_throttle_day} ||= Iczelia::Throttle->new(
    db     => $ctx->{db},
    table  => 'guestbook_throttle',
    max    => 5,
    window => 24 * 60 * 60,           # 5 per IP per 24h
  );

  # Public - Guestbook::register runs BEFORE Public::register so this
  # GET takes precedence over the generic _page handler.
  $router->get('/guestbook/', sub {render_public($ctx, $_[0])});
  $router->post('/guestbook/', sub {_submit($ctx, $_[0])});

  # Admin moderation
  require Iczelia::Handlers::Admin;
  my $gate = \&Iczelia::Handlers::Admin::gate;
  $router->get('/admin/guestbook/', sub {$gate->(\&_admin_list, $ctx, $_[0])});
  $router->post('/admin/guestbook/:id/approve',
    sub {$gate->(\&_admin_approve, $ctx, $_[0])});
  $router->post('/admin/guestbook/:id/reject',
    sub {$gate->(\&_admin_reject, $ctx, $_[0])});
  $router->post('/admin/guestbook/:id/reply',
    sub {$gate->(\&_admin_reply, $ctx, $_[0])});
  $router->post('/admin/guestbook/:id/delete',
    sub {$gate->(\&_admin_delete, $ctx, $_[0])});
}

# Public GET handler (replaces Public::_page for /guestbook/). Sets or
# reuses the anon-CSRF cookie and embeds its derived token in the form.
sub render_public {
  my ($ctx, $req) = @_;
  my ($cookie_value, $set) =
    $ctx->{auth}->anon_csrf_cookie($req->{cookies}{iczelia_csrf});
  my $token = $ctx->{auth}->anon_csrf_token($cookie_value, 'guestbook');

  my $page = $ctx->{db}->row(q{SELECT * FROM pages WHERE slug='guestbook'});

  my $entries = _load_entries($ctx);

  my $base_vars = $ctx->{render}->base_vars(
    title        => $page->{title} // 'iczelia :: guestbook',
    title_short  => 'guestbook',
    slug         => 'guestbook',
    page         => {is_guestbook => 1},
    meta         => {canonical => '/guestbook/', description => 'Sign the guestbook.'},
    data         => _cooked($ctx, $page),
    entries      => $entries,
    csrf         => $token,
    submitted    => $req->{qparams}{submitted} ? 1 : 0,
    rate_limited => $req->{qparams}{rl}        ? 1 : 0,
    error        => $req->{qparams}{e} || undef,
  );

  my $html = $ctx->{template}->render('views/guestbook.tpl', $base_vars);

  # The form embeds a per-visitor anti-CSRF token bound to the
  # iczelia_csrf cookie, so this page must never be served from a
  # shared cache (the nginx edge cache, a browser's bfcache, ...) --
  # one visitor's token reaching another browser is exactly the
  # "spurious 400 csrf" failure mode. no-store keeps it out of all of
  # them; _no_cache also keeps it out of the daemon's own cache.
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

sub _cooked {
  my ($ctx, $page) = @_;
  my $data = decode_json_hash($page->{data});
  my %out  = %$data;
  if (defined $data->{intro}) {
    my ($html) = Iczelia::Markup::render($data->{intro});
    $out{intro_html} = $html;
  }
  else {
    $out{intro_html} = '';
  }
  return \%out;
}

sub _load_entries {
  my ($ctx) = @_;
  my $rows = $ctx->{db}->all(
    q{
        SELECT id, posted_at, nickname, body_html, admin_replied_at, admin_reply_html
        FROM guestbook_entries
        WHERE approved_at IS NOT NULL AND rejected_at IS NULL
        ORDER BY posted_at DESC LIMIT } . GUESTBOOK_PUBLIC_ENTRIES_LIMIT
  );
  my @out;
  for my $r (@$rows) {
    push @out, {
      id        => $r->{id},
      nickname  => $r->{nickname},
      date_fmt  => ts_fmt($r->{posted_at}),
      body_html => $r->{body_html} // '',
      reply     => $r->{admin_reply_html}
      ? {
        date_fmt  => ts_fmt($r->{admin_replied_at}),
        body_html => $r->{admin_reply_html},
        }
      : undef,
    };
  }
  return \@out;
}

sub _submit {
  my ($ctx, $req) = @_;
  my $params = $req->{params};
  my $cookie = $req->{cookies}{iczelia_csrf} // '';
  my $token  = $params->{csrf}               // '';

  return Iczelia::HTTP::error(400, 'csrf')
    unless $ctx->{auth}->verify_anon_csrf($cookie, 'guestbook', $token);

  my $ip = $req->{remote} || '?';

  # Throttle BEFORE the honeypot so silent bot drops still cost a token.
  if (!$ctx->{gb_throttle_short}->allow($ip)) {
    return Iczelia::HTTP::redirect('/guestbook/?rl=1');
  }
  if (!$ctx->{gb_throttle_day}->check_only($ip)) {
    return Iczelia::HTTP::redirect('/guestbook/?rl=1');
  }

  # Honeypot: a bot that filled this gets a fake-success redirect.
  if (defined $params->{website} && length $params->{website}) {
    return Iczelia::HTTP::redirect('/guestbook/?submitted=1');
  }

  my $nick = $params->{nickname} // '';
  my $body = $params->{body}     // '';
  $nick =~ s/^\s+//;
  $nick =~ s/\s+$//;
  $body =~ s/\r\n/\n/g;

  if ($nick !~ /^[\w \-.]{1,40}$/) {
    return Iczelia::HTTP::redirect(
      '/guestbook/?e=' . escape_url('bad nickname'));
  }
  my ($ok, $why) = Iczelia::SafeMarkup::validate($body, {max => 4000});
  unless ($ok) {
    return Iczelia::HTTP::redirect('/guestbook/?e=' . escape_url($why));
  }

  my $ua = $req->{headers}{'user-agent'} // '';
  $ua = substr($ua, 0, 512) if length($ua) > 512;

  $ctx->{db}->do_(
    q{
        INSERT INTO guestbook_entries
          (posted_at, nickname, body_md, ip, user_agent)
          VALUES(strftime('%s','now'), ?, ?, ?, ?)
    }, $nick, $body, $ip, $ua
  );

  return Iczelia::HTTP::redirect('/guestbook/?submitted=1');
}

sub _admin_list {
  my ($ctx, $req) = @_;
  my $sid     = $req->{auth_sid};
  my $pending = $ctx->{db}->all(
    q{
        SELECT id, posted_at, nickname, body_md, ip, user_agent
        FROM guestbook_entries
        WHERE approved_at IS NULL AND rejected_at IS NULL
        ORDER BY posted_at DESC}
  );
  my $approved = $ctx->{db}->all(
    q{
        SELECT id, posted_at, nickname, body_html, approved_at,
               admin_reply_html, admin_replied_at
        FROM guestbook_entries
        WHERE approved_at IS NOT NULL AND rejected_at IS NULL
        ORDER BY posted_at DESC LIMIT } . GUESTBOOK_ADMIN_APPROVED_LIMIT
  );

  for my $e (@$pending, @$approved) {
    my @t = localtime $e->{posted_at};
    $e->{date_fmt} = sprintf(
      '%04d-%02d-%02d %02d:%02d',
      $t[5] + 1900,
      $t[4] + 1,
      $t[3], $t[2], $t[1]
    );
  }

  # Render preview HTML for pending entries
  for my $e (@$pending) {
    my ($prev, $math) = Iczelia::SafeMarkup::render($e->{body_md} // '');
    $e->{preview_html} = $ctx->{render}->substitute_math($prev, $math);
    $e->{csrf_approve} = $ctx->{auth}->csrf_token($sid, "gb:approve:$e->{id}");
    $e->{csrf_reject}  = $ctx->{auth}->csrf_token($sid, "gb:reject:$e->{id}");
    $e->{csrf_delete}  = $ctx->{auth}->csrf_token($sid, "gb:delete:$e->{id}");
  }
  for my $e (@$approved) {
    $e->{csrf_reply}  = $ctx->{auth}->csrf_token($sid, "gb:reply:$e->{id}");
    $e->{csrf_delete} = $ctx->{auth}->csrf_token($sid, "gb:delete:$e->{id}");
  }

  require Iczelia::Handlers::Admin;
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_guestbook.tpl',
    title    => 'guestbook moderation',
    pending  => $pending,
    approved => $approved,
  );
}

sub _admin_approve {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "gb:approve:$id");
  return $err if $err;
  my $row =
    $ctx->{db}->row('SELECT body_md FROM guestbook_entries WHERE id=?', $id);
  return Iczelia::HTTP::error(404) unless $row;
  my ($html, $math) = Iczelia::SafeMarkup::render($row->{body_md} // '');
  $html = $ctx->{render}->substitute_math($html, $math);
  $ctx->{db}->do_(
    q{
        UPDATE guestbook_entries
           SET approved_at=strftime('%s','now'), rejected_at=NULL,
               body_html=?
         WHERE id=?}, $html, $id
  );
  $ctx->{render}->invalidate_page('guestbook');
  return Iczelia::HTTP::redirect('/admin/guestbook/');
}

sub _admin_reject {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "gb:reject:$id");
  return $err if $err;
  $ctx->{db}->do_(
    q{
        UPDATE guestbook_entries SET rejected_at=strftime('%s','now')
         WHERE id=?}, $id
  );
  $ctx->{render}->invalidate_page('guestbook');
  return Iczelia::HTTP::redirect('/admin/guestbook/');
}

sub _admin_reply {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "gb:reply:$id");
  return $err if $err;
  my $body = $req->{params}{reply} // '';
  my ($ok, $why) = Iczelia::SafeMarkup::validate($body, {max => 4000});
  return Iczelia::HTTP::error(400, $why) unless $ok;
  my ($html, $math) = Iczelia::SafeMarkup::render($body);
  $html = $ctx->{render}->substitute_math($html, $math);
  $ctx->{db}->do_(
    q{
        UPDATE guestbook_entries
           SET admin_reply_md=?, admin_reply_html=?,
               admin_replied_at=strftime('%s','now')
         WHERE id=?}, $body, $html, $id
  );
  $ctx->{render}->invalidate_page('guestbook');
  return Iczelia::HTTP::redirect('/admin/guestbook/');
}

sub _admin_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = $ctx->{auth}->require_csrf($req, "gb:delete:$id");
  return $err if $err;
  $ctx->{db}->do_('DELETE FROM guestbook_entries WHERE id=?', $id);
  $ctx->{render}->invalidate_page('guestbook');
  return Iczelia::HTTP::redirect('/admin/guestbook/');
}

1;
