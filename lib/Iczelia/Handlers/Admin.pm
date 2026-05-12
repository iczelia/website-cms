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
use Iczelia::HTTP      ();
use Iczelia::Util      qw(escape_html escape_attr slugify);
use Iczelia::Schema    ();
use Iczelia::Content   ();
use Iczelia::Markup    ();
use Iczelia::Highlight ();
use Iczelia::Media     ();
use JSON::PP           ();

my $JSON = JSON::PP->new->utf8(0);

sub register {
  my ($class, $router, $ctx) = @_;

  # Hang the schema/content helpers off $ctx once per worker.
  $ctx->{schema} ||=
    Iczelia::Schema->new(dir => $ctx->{cfg}{'share-dir'} . '/templates/pages');
  $ctx->{content} ||= Iczelia::Content->new(
    db     => $ctx->{db},
    render => $ctx->{render}
  );

  $router->get('/admin/',      sub {_gate(\&_dashboard, $ctx, $_[0])});
  $router->get('/admin/login', sub {_login_form($ctx, $_[0])});
  $router->post('/admin/login',  sub {_login_submit($ctx, $_[0])});
  $router->post('/admin/logout', sub {_logout($ctx, $_[0])});

  $router->get('/admin/edit/:slug', sub {_gate(\&_edit_page, $ctx, $_[0])});
  $router->post('/admin/edit/:slug', sub {_gate(\&_save_page, $ctx, $_[0])});

  for my $kind (qw(blog journal)) {
    $router->get("/admin/$kind/",
      sub {_gate(\&_post_list, $ctx, $_[0], $kind)});
    $router->get("/admin/$kind/new",
      sub {_gate(\&_post_new, $ctx, $_[0], $kind)});
    $router->post("/admin/$kind/new",
      sub {_gate(\&_post_create, $ctx, $_[0], $kind)});
    $router->get("/admin/$kind/:slug/edit",
      sub {_gate(\&_post_edit, $ctx, $_[0], $kind)});
    $router->post("/admin/$kind/:slug/edit",
      sub {_gate(\&_post_update, $ctx, $_[0], $kind)});
    $router->post("/admin/$kind/:slug/delete",
      sub {_gate(\&_post_delete, $ctx, $_[0], $kind)});
    $router->get("/admin/$kind/:slug/revisions",
      sub {_gate(\&_revisions_list, $ctx, $_[0], $kind)});
    $router->get("/admin/$kind/:slug/revisions/:rev",
      sub {_gate(\&_revisions_view, $ctx, $_[0], $kind)});
    $router->post(
      "/admin/$kind/:slug/revisions/:rev/restore",
      sub {_gate(\&_revisions_restore, $ctx, $_[0], $kind)}
    );
    $router->post(
      "/admin/$kind/:slug/aliases/:from/delete",
      sub {_gate(\&_alias_delete, $ctx, $_[0], $kind)}
    );
  }

  $router->get('/admin/updates/', sub {_gate(\&_updates_form, $ctx, $_[0])});
  $router->post('/admin/updates/', sub {_gate(\&_updates_save, $ctx, $_[0])});

  $router->get('/admin/activity/', sub {_gate(\&_activity_view, $ctx, $_[0])});
  $router->post('/admin/activity/currently',
    sub {_gate(\&_activity_currently, $ctx, $_[0])});
  $router->post('/admin/activity/refresh',
    sub {_gate(\&_activity_refresh, $ctx, $_[0])});

  $router->get('/admin/webring/', sub {_gate(\&_webring_form, $ctx, $_[0])});
  $router->post('/admin/webring/', sub {_gate(\&_webring_save, $ctx, $_[0])});

  $router->get('/admin/settings/', sub {_gate(\&_settings_form, $ctx, $_[0])});
  $router->post('/admin/settings/',
    sub {_gate(\&_settings_save, $ctx, $_[0])});
  $router->get('/admin/settings/theme-preview',
    sub {_gate(\&_theme_preview, $ctx, $_[0])});

  $router->post('/admin/preview', sub {_gate(\&_preview, $ctx, $_[0])});

  $router->get('/admin/media/', sub {_gate(\&_media_list, $ctx, $_[0])});
  $router->post('/admin/media/upload',
    sub {_gate(\&_media_upload, $ctx, $_[0])});
  $router->post('/admin/media/:id/delete',
    sub {_gate(\&_media_delete, $ctx, $_[0])});

  $router->get('/admin/pgp/', sub {_gate(\&_pgp_form, $ctx, $_[0])});
  $router->post('/admin/pgp/',       sub {_gate(\&_pgp_upload, $ctx, $_[0])});
  $router->post('/admin/pgp/delete', sub {_gate(\&_pgp_delete, $ctx, $_[0])});

  $router->post('/admin/cache/drop', sub {_gate(\&_cache_drop, $ctx, $_[0])});
  $router->post('/admin/search/rebuild',
    sub {_gate(\&_search_rebuild, $ctx, $_[0])});

  $router->get('/admin/dynamic/', sub {_gate(\&_dynamic_list, $ctx, $_[0])});
  $router->get('/admin/dynamic/new', sub {_gate(\&_dynamic_new, $ctx, $_[0])});
  $router->post('/admin/dynamic/new',
    sub {_gate(\&_dynamic_create, $ctx, $_[0])});
  $router->get('/admin/dynamic/:id/edit',
    sub {_gate(\&_dynamic_edit, $ctx, $_[0])});
  $router->post('/admin/dynamic/:id/edit',
    sub {_gate(\&_dynamic_update, $ctx, $_[0])});
  $router->post('/admin/dynamic/:id/delete',
    sub {_gate(\&_dynamic_delete, $ctx, $_[0])});

  $router->get('/admin/highlight/',    sub {_gate(\&_lang_list, $ctx, $_[0])});
  $router->get('/admin/highlight/new', sub {_gate(\&_lang_new,  $ctx, $_[0])});
  $router->post('/admin/highlight/new',
    sub {_gate(\&_lang_create, $ctx, $_[0])});
  $router->get('/admin/highlight/:id/edit',
    sub {_gate(\&_lang_edit, $ctx, $_[0])});
  $router->post('/admin/highlight/:id/edit',
    sub {_gate(\&_lang_update, $ctx, $_[0])});
  $router->post('/admin/highlight/:id/delete',
    sub {_gate(\&_lang_delete, $ctx, $_[0])});
}

# Public so Backup / Guestbook / Analytics can hang their admin routes
# off the same gate without reaching for private symbols.
sub gate {my ($fn, $ctx, @r) = @_; $ctx->{auth}->gate($fn, $ctx, @r)}
*_gate = \&gate;

sub _csrf_or_400 {
  my ($ctx, $req, $form) = @_;
  $ctx->{auth}->require_csrf($req, $form);
}

sub _admin_vars {
  my ($ctx, $req, %extra) = @_;
  my $sid     = $req->{auth_sid};
  my $pending = $ctx->{db}->one(
    q{SELECT COUNT(*) FROM guestbook_entries
          WHERE approved_at IS NULL AND rejected_at IS NULL}
  );

  # csrf_form: single-form views' scalar token.
  # csrf_extra: multi-form views' hashref of named tokens to merge.
  my $csrf_form  = delete $extra{csrf_form} // '';
  my $csrf_extra = delete $extra{csrf_extra} || {};

  my $csrf_hash = {
    logout     => $ctx->{auth}->csrf_token($sid, 'logout'),
    upload     => $ctx->{auth}->csrf_token($sid, 'upload'),
    preview    => $ctx->{auth}->csrf_token($sid, 'preview'),
    cache_drop => $ctx->{auth}->csrf_token($sid, 'cache:drop'),
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
*admin_vars = \&_admin_vars;

sub _ts_fmt {
  my ($ts) = @_;
  return '' unless defined $ts;
  my @t = localtime $ts;
  return sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3];
}

# Unix timestamp -> 'YYYY-MM-DDTHH:MM' (UTC) for a datetime-local input.
sub _ts_to_local_input {
  my ($ts) = @_;
  return '' unless defined $ts && length $ts;
  my @t = gmtime $ts;
  return sprintf '%04d-%02d-%02dT%02d:%02d',
    $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1];
}

sub _login_form {
  my ($ctx, $req) = @_;
  my ($u) = $ctx->{auth}->current_user($req);
  return Iczelia::HTTP::redirect('/admin/') if $u;

  my ($cookie_value, $set) =
    $ctx->{auth}->anon_csrf_cookie($req->{cookies}{iczelia_csrf});
  my $token = $ctx->{auth}->anon_csrf_token($cookie_value, 'login');

  my $err = $req->{qparams}{e} // '';
  my $msg =
      $err eq 'bad' ? 'invalid credentials'
    : $err eq 'thr' ? 'too many attempts; try later'
    : $err eq 'err' ? 'something went wrong'
    :                 undef;
  my $html = $ctx->{template}->render(
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
        secure   => Iczelia::Auth::is_https($req),
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
    unless $ctx->{auth}->verify_anon_csrf($cookie, 'login', $token);

  my ($sid, $err) = $ctx->{auth}->login(
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
  $resp->{cookies} = [$ctx->{auth}->session_cookie($sid, $req)];
  return $resp;
}

sub _logout {
  my ($ctx, $req) = @_;
  my ($u,   $sid) = $ctx->{auth}->current_user($req);
  if ($u) {
    my $expected = $ctx->{auth}->csrf_token($sid, 'logout');
    if (($req->{params}{csrf} // '') eq $expected) {
      $ctx->{auth}->logout($sid);
    }
  }
  my $resp = Iczelia::HTTP::redirect('/admin/login');
  $resp->{cookies} = [$ctx->{auth}->session_cookie('', $req)];
  return $resp;
}

sub _dashboard {
  my ($ctx, $req) = @_;
  my $db = $ctx->{db};
  my $pages =
    $db->all(q{SELECT slug, title, updated_at FROM pages ORDER BY slug});
  for my $p (@$pages) {
    $p->{updated_fmt} = _ts_fmt($p->{updated_at});
  }
  my $blog = $db->all(
    q{SELECT slug, title, date, draft FROM posts
                             WHERE kind='blog'
                             ORDER BY date DESC, created_at DESC, id DESC LIMIT 50}
  );
  my $journal = $db->all(
    q{SELECT slug, title, date, draft FROM posts
                             WHERE kind='journal'
                             ORDER BY date DESC, created_at DESC, id DESC LIMIT 50}
  );

  require Iczelia::Warmer;

  # Reads the snapshot the background warmer maintains; never walks
  # post bodies. See Warmer::stats / Warmer::_pass.
  my $math = eval {Iczelia::Warmer->stats($db)}
    || {total => 0, cached => 0, missing => 0, cache_rows => 0};
  $math->{pct} =
    $math->{total}
    ? int($math->{cached} * 100 / $math->{total})
    : 100;

  my $msg = $req->{qparams}{msg} // '';
  my $flash;
  if ($msg eq 'cache-dropped') {
    $flash = {
      kind => 'ok',
      text => 'cache dropped - next visit pays a full re-render.'
    };
  }
  elsif ($msg eq 'search-rebuilt') {
    $flash = {kind => 'ok', text => 'search index rebuilt.'};
  }
  elsif (length $msg) {

    # Sanitize unknown msgs so a bookmarked URL with random text
    # can't inject HTML into the flash banner.
    my $clean = substr($msg, 0, 80);
    $clean =~ s/[^\w\- ]//g;
    $flash = {kind => 'ok', text => $clean} if length $clean;
  }

  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_dashboard.tpl',
      _admin_vars(
        $ctx, $req,
        title      => 'dashboard',
        pages      => $pages,
        blog       => $blog,
        journal    => $journal,
        math       => $math,
        flash      => $flash,
        csrf_extra => {
          cache_drop =>
            $ctx->{auth}->csrf_token($req->{auth_sid}, 'cache:drop'),
          search_rebuild =>
            $ctx->{auth}->csrf_token($req->{auth_sid}, 'search:rebuild'),
        },
      )
    )
  );
}

sub _edit_page {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $page = $ctx->{content}->get_page($slug)
    or return Iczelia::HTTP::error(404, 'no such page');

  my $sch = eval {$ctx->{schema}->load($page->{template})}
    or return Iczelia::HTTP::error(500,
    "no schema for template '$page->{template}'");

  my $data = $ctx->{schema}->decode($page->{data});
  my $sid  = $req->{auth_sid};
  my $csrf = $ctx->{auth}->csrf_token($sid, "page:$slug");

  my @fields;
  for my $f (@{$sch->{fields}}) {
    push @fields, _field_for_form($f, $data->{$f->{name}});
  }

  my $html = $ctx->{template}->render(
    'views/admin_edit_page.tpl',
    _admin_vars(
      $ctx, $req,
      title     => "edit $slug",
      csrf_form => $csrf,
      page      => {
        slug        => $slug,
        template    => $page->{template},
        updated_fmt => _ts_fmt($page->{updated_at}),
      },
      fields => \@fields,
    )
  );
  return Iczelia::HTTP::html($html);
}

sub _save_page {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $page = $ctx->{content}->get_page($slug)
    or return Iczelia::HTTP::error(404);
  my $err = _csrf_or_400($ctx, $req, "page:$slug");
  return $err if $err;

  my ($data, $errs) =
    $ctx->{schema}->parse_form($page->{template}, $req->{params});
  my $json = $ctx->{schema}->encode($data);
  $ctx->{content}->save_page($slug, $page->{title}, $page->{template}, $json);
  return Iczelia::HTTP::redirect('/admin/');
}

# Per-field record (with input_html pre-rendered) for admin_edit_page.tpl.
# Every value placed in attribute context goes through escape_attr -
# the schema files are admin-trusted but a typo shouldn't yield XSS.
sub _field_for_form {
  my ($f, $value) = @_;
  my $kind   = $f->{kind};
  my $name   = $f->{name};
  my $name_a = escape_attr($name);
  my $rec    = {
    name  => $name,
    kind  => $kind,
    label => $f->{label} // $name,
    help  => $f->{help},
  };

  if ($kind eq 'markdown') {
    my $v = escape_html(defined $value ? $value : '');
    $rec->{input_html} =
      qq{<textarea class="cm-md" name="$name_a" rows="10">$v</textarea>};
  }
  elsif ($kind eq 'markdown_inline') {
    my $v = escape_attr(defined $value ? $value : '');
    $rec->{input_html} = qq{<input type="text" name="$name_a" value="$v">};
  }
  elsif ($kind eq 'text') {
    my $v = escape_attr(defined $value ? $value : '');
    my $max =
      defined $f->{max} ? ' maxlength="' . escape_attr($f->{max}) . '"' : '';
    $rec->{input_html} = qq{<input type="text" name="$name_a" value="$v"$max>};
  }
  elsif ($kind eq 'int') {
    my $v   = defined $value    ? (0 + $value) : ($f->{default} // 0);
    my $min = defined $f->{min} ? ' min="' . escape_attr($f->{min}) . '"' : '';
    my $max = defined $f->{max} ? ' max="' . escape_attr($f->{max}) . '"' : '';
    $rec->{input_html} =
      qq{<input type="number" name="$name_a" value="$v"$min$max>};
  }
  elsif ($kind eq 'bool') {
    my $checked = $value ? ' checked' : '';
    $rec->{input_html} =
      qq{<label><input type="checkbox" name="$name_a" value="1"$checked> on</label>};
  }
  elsif ($kind eq 'kv-table') {
    $rec->{input_html} = _kvtable_html($f, $value || []);
  }
  else {
    $rec->{input_html} =
      '<em>unsupported field kind: ' . escape_html($kind) . '</em>';
  }
  return $rec;
}

sub _kvtable_html {
  my ($f, $rows) = @_;
  my @bits;
  my $field_a = escape_attr($f->{name});
  push @bits, qq{<table class="cms-kvtable" data-field="$field_a">};
  push @bits, '<thead><tr>';
  for my $c (@{$f->{columns}}) {
    my $w =
      defined $c->{width}
      ? ' style="width: ' . escape_attr($c->{width}) . '"'
      : '';
    push @bits, '<th' . $w . '>' . escape_html($c->{label}) . '</th>';
  }
  push @bits, '<th class="cms-kvtable-actions"></th></tr></thead><tbody>';
  my $idx = 0;
  for my $r (@$rows) {
    push @bits, '<tr>';
    for my $c (@{$f->{columns}}) {
      my $v  = escape_attr($r->{$c->{name}} // '');
      my $nm = escape_attr($f->{name} . "__row${idx}__" . $c->{name});
      push @bits, qq{<td><input type="text" name="$nm" value="$v"></td>};
    }
    push @bits,
      '<td class="cms-kvtable-actions"><button type="button" class="cms-row-del">&times;</button></td>';
    push @bits, '</tr>';
    $idx++;
  }

  # Always provide one trailing empty row so users can extend without JS.
  push @bits, '<tr>';
  for my $c (@{$f->{columns}}) {
    my $nm = escape_attr($f->{name} . "__row${idx}__" . $c->{name});
    push @bits, qq{<td><input type="text" name="$nm" value=""></td>};
  }
  push @bits, '<td></td></tr>';
  push @bits, '</tbody></table>';
  push @bits,
    qq{<p class="cms-kvtable-add"><button type="button" data-field="$field_a" class="cms-row-add">+ add row</button></p>};
  return join '', @bits;
}

sub _post_list {
  my ($ctx, $req, $kind) = @_;
  my $posts = $ctx->{content}->list_posts($kind);
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_post_list.tpl',
      _admin_vars(
        $ctx, $req,
        title => "$kind posts",
        kind  => $kind,
        posts => $posts,
      )
    )
  );
}

sub _post_new {
  my ($ctx, $req, $kind) = @_;
  return _render_post_form($ctx, $req, $kind, undef);
}

sub _post_edit {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $post = $ctx->{content}->get_post($kind, $slug)
    or return Iczelia::HTTP::error(404);
  return _render_post_form($ctx, $req, $kind, $post);
}

sub _render_post_form {
  my ($ctx, $req, $kind, $post) = @_;
  my $sid       = $req->{auth_sid};
  my $form_name = $post ? "post:$kind:$post->{slug}"      : "post-new:$kind";
  my $action  = $post ? "/admin/$kind/$post->{slug}/edit" : "/admin/$kind/new";
  my $aliases = [];
  if ($post) {
    my $rows = $ctx->{db}->all(
      q{SELECT from_slug, created_at FROM post_aliases
               WHERE post_id=? ORDER BY created_at DESC}, $post->{id}
    );
    for my $a (@$rows) {
      push @$aliases,
        {
        from_slug => $a->{from_slug},
        csrf_del  => $ctx->{auth}
          ->csrf_token($sid, "alias-del:$kind:$post->{slug}:$a->{from_slug}"),
        };
    }
  }
  my $rec =
    $post
    ? {
    id             => $post->{id},
    slug           => $post->{slug},
    title          => $post->{title},
    date           => $post->{date},
    tags           => $post->{tags},
    body           => $post->{body},
    draft          => $post->{draft},
    publish_at     => $post->{publish_at},
    publish_at_fmt => _ts_to_local_input($post->{publish_at}),
    word_count     => $post->{word_count} // 0,
    updated_fmt    => _ts_fmt($post->{updated_at}),
    aliases        => $aliases,
    }
    : {
    id             => 0,
    slug           => '',
    title          => '',
    date           => _ts_fmt(time),
    tags           => '',
    body           => '',
    draft          => 0,
    publish_at     => undef,
    publish_at_fmt => '',
    word_count     => 0,
    aliases        => [],
    };

  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_edit_post.tpl',
      _admin_vars(
        $ctx, $req,
        title       => $post ? "edit $kind/$post->{slug}" : "new $kind",
        kind        => $kind,
        post        => $rec,
        form_action => $action,
        csrf_form   => $ctx->{auth}->csrf_token($sid, $form_name),
      )
    )
  );
}

use constant POST_BODY_MAX  => 256 * 1024;
use constant TITLE_MAX      => 200;
use constant TAGS_MAX       => 200;
use constant MEDIA_BODY_MAX => 4 * 1024 * 1024;
use constant PGP_BODY_MAX   => 256 * 1024;

sub _validate_post {
  my ($p, $old_slug) = @_;
  my $title = $p->{title} // '';
  my $body  = $p->{body}  // '';
  return (undef, 'title required') unless length $title;
  return (undef, 'title too long') if length($title) > TITLE_MAX;
  return (undef, 'body too long')  if length($body) > POST_BODY_MAX;
  return (undef, 'tags too long')  if length($p->{tags} // '') > TAGS_MAX;
  my $slug = $p->{slug} // '';
  $slug = $old_slug if !length $slug && defined $old_slug;

  if (length $slug) {
    $slug = Iczelia::Util::slugify($slug);
    return (undef, 'invalid slug') unless length $slug;
  }
  my $date = $p->{date} || '';
  return (undef, 'invalid date') unless $date =~ /^\d{4}-\d{2}-\d{2}$/;

  # publish_at is optional. Reject anything older than ~yesterday: a
  # past timestamp is almost always a typo for the `date` field.
  my $pub_in = $p->{publish_at} // '';
  my $publish_at;
  if (length $pub_in) {
    $publish_at = Iczelia::Content::_normalize_publish_at($pub_in);
    return (undef, 'invalid publish_at')
      unless defined $publish_at;
    return (undef, 'publish_at in the past')
      if $publish_at < time - 86400;
  }

  return (
    {
      title      => $title,
      date       => $date,
      slug       => $slug,
      tags       => $p->{tags} // '',
      body       => $body,
      draft      => $p->{draft} ? 1 : 0,
      publish_at => $publish_at,
    },
    undef
  );
}

sub _post_create {
  my ($ctx, $req, $kind) = @_;
  my $err = _csrf_or_400($ctx, $req, "post-new:$kind");
  return $err if $err;
  my ($rec, $why) = _validate_post($req->{params}, undef);
  return Iczelia::HTTP::error(400, $why) unless $rec;
  my $slug = $ctx->{content}->create_post($kind, $rec);
  return Iczelia::HTTP::redirect("/admin/$kind/$slug/edit");
}

sub _post_update {
  my ($ctx, $req, $kind) = @_;
  my $old = $req->{caps}{slug};
  my $err = _csrf_or_400($ctx, $req, "post:$kind:$old");
  return $err if $err;
  my ($rec, $why) = _validate_post($req->{params}, $old);
  return Iczelia::HTTP::error(400, $why) unless $rec;
  $rec->{author} = $req->{auth_user};
  my $new = $ctx->{content}->update_post($kind, $old, $rec);
  return Iczelia::HTTP::redirect("/admin/$kind/$new/edit");
}

sub _post_delete {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $err  = _csrf_or_400($ctx, $req, "post:$kind:$slug");
  return $err if $err;
  $ctx->{content}->delete_post($kind, $slug);
  return Iczelia::HTTP::redirect("/admin/$kind/");
}

sub _revisions_list {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $post = $ctx->{content}->get_post($kind, $slug)
    or return Iczelia::HTTP::error(404);
  my $rows = $ctx->{db}->all(
    q{SELECT revision_num, title, date, author, created_at, draft, publish_at
            FROM post_revisions
           WHERE post_id=?
        ORDER BY revision_num DESC}, $post->{id}
  );
  my $sid = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{created_fmt}  = _ts_fmt($r->{created_at});
    $r->{csrf_restore} = $ctx->{auth}
      ->csrf_token($sid, "rev-restore:$kind:$slug:$r->{revision_num}");
  }
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_post_revisions.tpl',
      _admin_vars(
        $ctx, $req,
        title     => "$kind/$slug revisions",
        kind      => $kind,
        slug      => $slug,
        post      => $post,
        revisions => $rows,
      )
    )
  );
}

sub _revisions_view {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $rev  = $req->{caps}{rev} + 0;
  my $post = $ctx->{content}->get_post($kind, $slug)
    or return Iczelia::HTTP::error(404);
  my $row =
    $ctx->{db}
    ->row(q{SELECT * FROM post_revisions WHERE post_id=? AND revision_num=?},
    $post->{id}, $rev);
  return Iczelia::HTTP::error(404) unless $row;
  my $sid = $req->{auth_sid};
  $row->{created_fmt} = _ts_fmt($row->{created_at});
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_post_revision_view.tpl',
      _admin_vars(
        $ctx, $req,
        title        => "$kind/$slug rev $rev",
        kind         => $kind,
        slug         => $slug,
        post         => $post,
        rev          => $row,
        csrf_restore =>
          $ctx->{auth}->csrf_token($sid, "rev-restore:$kind:$slug:$rev"),
      )
    )
  );
}

sub _revisions_restore {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $rev  = $req->{caps}{rev} + 0;
  my $err  = _csrf_or_400($ctx, $req, "rev-restore:$kind:$slug:$rev");
  return $err if $err;
  my $post = $ctx->{content}->get_post($kind, $slug)
    or return Iczelia::HTTP::error(404);
  my $row =
    $ctx->{db}
    ->row(q{SELECT * FROM post_revisions WHERE post_id=? AND revision_num=?},
    $post->{id}, $rev);
  return Iczelia::HTTP::error(404) unless $row;

  # Restore is a NEW save: the restore itself becomes the next
  # revision and the original history stays intact.
  my $new_slug = $ctx->{content}->update_post(
    $kind, $slug,
    {
      title      => $row->{title},
      body       => $row->{body},
      tags       => $row->{tags},
      date       => $row->{date},
      slug       => $slug,
      draft      => $row->{draft},
      publish_at => $row->{publish_at},
      author     => $req->{auth_user},
    }
  );
  return Iczelia::HTTP::redirect("/admin/$kind/$new_slug/edit");
}

sub _alias_delete {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $from = $req->{caps}{from};
  my $err  = _csrf_or_400($ctx, $req, "alias-del:$kind:$slug:$from");
  return $err if $err;
  $ctx->{db}->do_('DELETE FROM post_aliases WHERE kind=? AND from_slug=?',
    $kind, $from);
  $ctx->{cache}->bust("/$kind/$from/") if $ctx->{cache};
  return Iczelia::HTTP::redirect("/admin/$kind/$slug/edit");
}

sub _updates_form {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{content}->list_updates;
  my $sid  = $req->{auth_sid};

  my $field = {
    name    => 'rows',
    kind    => 'kv-table',
    label   => 'updates',
    columns => [
      {name => 'date', label => 'date', kind => 'text', width => '20%'},
      {
        name  => 'body',
        label => 'body',
        kind  => 'markdown_inline',
        width => '80%'
      },
    ],
  };
  my @data        = map {{date => $_->{date}, body => $_->{body}}} @$rows;
  my $html_inputs = _kvtable_html($field, \@data);

  my $html = _simple_form_render(
    $ctx, $req,
    title  => 'updates',
    action => '/admin/updates/',
    csrf   => $ctx->{auth}->csrf_token($sid, 'updates'),
    body   => $html_inputs,
  );
  return Iczelia::HTTP::html($html);
}

sub _updates_save {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'updates');
  return $err if $err;
  my @rows = grep {
    ($_->{date} // '') =~ /^\d{4}-\d{2}-\d{2}$/
      && length($_->{body} // '')
  } _kvtable_rows_from_params($req->{params});
  $ctx->{content}->replace_updates(\@rows);
  return Iczelia::HTTP::redirect('/admin/updates/');
}

# Reassemble a kv-table form (rows__row<N>__<col>=val) into row
# hashes, returned in N order.
sub _kvtable_rows_from_params {
  my ($params) = @_;
  my %by_row;
  for my $k (keys %$params) {
    if ($k =~ /^rows__row(\d+)__(\w+)$/) {
      $by_row{$1}{$2} = $params->{$k};
    }
  }
  return map {$by_row{$_}} sort {$a <=> $b} keys %by_row;
}

sub _activity_view {
  my ($ctx, $req) = @_;
  my $rows =
    $ctx->{db}->all('SELECT * FROM activity ORDER BY source, position');
  my %by_src;
  for my $r (@$rows) {push @{$by_src{$r->{source}}}, $r}
  my $currently =
    ($by_src{currently} && @{$by_src{currently}})
    ? $by_src{currently}[0]{text}
    : '';

  my $sid = $req->{auth_sid};
  my @sections;
  for my $s (qw(github mastodon bluesky)) {
    push @sections,
      {
      source => $s,
      rows   => $by_src{$s} || [],
      };
  }
  my $html = $ctx->{template}->render(
    'views/admin_activity.tpl',
    _admin_vars(
      $ctx, $req,
      title      => 'activity',
      sections   => \@sections,
      currently  => $currently,
      csrf_extra => {
        currently => $ctx->{auth}->csrf_token($sid, 'activity:currently'),
        refresh   => $ctx->{auth}->csrf_token($sid, 'activity:refresh'),
      },
    )
  );
  return Iczelia::HTTP::html($html);
}

sub _activity_currently {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'activity:currently');
  return $err if $err;
  $ctx->{content}->set_currently($req->{params}{currently} // '');
  return Iczelia::HTTP::redirect('/admin/activity/');
}

sub _activity_refresh {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'activity:refresh');
  return $err if $err;
  if ($ctx->{fetcher}) {
    eval {$ctx->{fetcher}->run_all};
  }
  return Iczelia::HTTP::redirect('/admin/activity/');
}

# Wipe response_cache + tex_cache + per-row rendered_html. The next
# visitor pays a full re-render.
sub _cache_drop {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'cache:drop');
  return $err if $err;
  my $db = $ctx->{db};
  $db->tx(
    sub {
      my $d = shift;
      $d->do_('DELETE FROM response_cache');
      $d->do_('DELETE FROM tex_cache');
      $d->do_('UPDATE pages SET rendered_html = NULL');
      $d->do_('UPDATE posts SET rendered_html = NULL');
    }
  );
  return Iczelia::HTTP::redirect('/admin/?msg=cache-dropped');
}

# Force-rebuild the FTS5 index from posts. Useful after a manual sqlite
# edit, or to recover if the index ever drifts from the source rows.
sub _search_rebuild {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'search:rebuild');
  return $err if $err;
  eval {$ctx->{db}->do_(q{INSERT INTO posts_fts(posts_fts) VALUES('rebuild')})};
  return Iczelia::HTTP::redirect('/admin/?msg=search-rebuilt');
}

sub _webring_form {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{content}->list_webring;
  my $sid  = $req->{auth_sid};

  my $field = {
    name    => 'rows',
    kind    => 'kv-table',
    label   => 'webring members',
    columns => [
      {name => 'section', label => 'section', kind => 'text', width => '15%'},
      {name => 'name',    label => 'name',    kind => 'text', width => '20%'},
      {name => 'url',     label => 'url',     kind => 'text', width => '35%'},
      {
        name  => 'image_url',
        label => '88x31 img',
        kind  => 'text',
        width => '30%'
      },
    ],
  };
  my @data = map {
    {
      section   => $_->{section} // 'others',
      name      => $_->{name},
      url       => $_->{url}       // '',
      image_url => $_->{image_url} // '',
    }
  } @$rows;
  my $html_inputs = _kvtable_html($field, \@data);

  my $html = _simple_form_render(
    $ctx, $req,
    title  => 'webring',
    action => '/admin/webring/',
    csrf   => $ctx->{auth}->csrf_token($sid, 'webring'),
    body   => $html_inputs,
  );
  return Iczelia::HTTP::html($html);
}

sub _webring_save {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'webring');
  return $err if $err;
  my @rows =
    grep {length($_->{name} // '')} _kvtable_rows_from_params($req->{params});
  $ctx->{content}->replace_webring(\@rows);
  return Iczelia::HTTP::redirect('/admin/webring/');
}

# Single source of truth for editable settings: drives both the form
# layout and the save-time allowlist.
my @SETTINGS_GROUPS = (
  [
    'site', 'site',
    [
      qw(site.title site.tagline site.description site.keywords
        site.og_image site.author site.email site.base_url
        site.copyright site.copyright_start site.copyright_holder)
    ]
  ],
  [
    'social',
    'social',
    [
      qw(github.username github.url
        mastodon.handle mastodon.url mastodon.feed_url
        bluesky.handle bluesky.url)
    ]
  ],
  [
    'fetcher',
    'activity fetcher',
    [qw(fetcher.timeout_s fetcher.user_agent)]
  ],
  [
    'math',
    'math (TeX rendering)',
    [
      qw(math.dpi math.inline_pt math.display_pt
        math.glow_radius math.glow_opacity)
    ]
  ],
  [
    'figure',
    'figure',
    [qw(figure.bg figure.border)]
  ],
  [
    'theme',
    'theme - code colours',
    [
      qw(theme.code.bg theme.code.border theme.code.text
        theme.code.com theme.code.str theme.code.num
        theme.code.kw  theme.code.typ theme.code.cst
        theme.code.pre theme.code.attr theme.code.lt
        theme.code.mac theme.code.reg theme.code.lbl
        theme.code.gly theme.code.sys theme.code.op
        theme.code.pn  theme.code.id)
    ]
  ],
);

sub _settings_keys {
  my %seen;
  for my $g (@SETTINGS_GROUPS) {$seen{$_} = 1 for @{$g->[2]}}
  return \%seen;
}

sub _settings_form {
  my ($ctx, $req) = @_;
  my $kv  = $ctx->{content}->all_settings;
  my $sid = $req->{auth_sid};

  my @bits;
  for my $g (@SETTINGS_GROUPS) {
    my ($id, $label, $keys) = @$g;
    push @bits,
      qq{<fieldset class="cms-settings-group cms-settings-group-$id"><legend>$label</legend><table class="cms-settings"><tbody>};
    for my $k (@$keys) {
      my $v = escape_attr($kv->{$k} // '');
      (my $display = $k) =~ s/^\Q$id\E\.//;
      push @bits,
        qq{<tr><td><label for="s_$k">$display</label></td><td><input id="s_$k" type="text" name="$k" value="$v"></td></tr>};
    }
    push @bits, qq{</tbody></table></fieldset>};
  }
  push @bits,
    qq{<p class="cms-help"><a href="/admin/settings/theme-preview" target="_blank" rel="noopener">preview the current code theme &raquo;</a></p>};

  return Iczelia::HTTP::html(
    _simple_form_render(
      $ctx, $req,
      title  => 'settings',
      action => '/admin/settings/',
      csrf   => $ctx->{auth}->csrf_token($sid, 'settings'),
      body   => join('', @bits),
    )
  );
}

sub _settings_save {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'settings');
  return $err if $err;
  my $allowed = _settings_keys();
  my %kv;
  for my $k (keys %{$req->{params}}) {
    $kv{$k} = $req->{params}{$k} if $allowed->{$k};
  }
  $ctx->{content}->set_settings(\%kv);
  return Iczelia::HTTP::redirect('/admin/settings/');
}

# Exercises every hl-* class plus realistic snippets, so theme.code.*
# tweaks have one canonical preview surface.
sub _theme_preview {
  my ($ctx, $req) = @_;
  my @cls =
    qw(com str chr num kw typ cst pre op pn id attr lt mac reg lbl gly sys);
  my @samples = (
    [
      'c', q{int main(void) {
    /* hello */
    char *s = "world";
    if (s == NULL) return 0;
    return printf("hi %s\n", s);
}}
    ],
    [
      'python', q{# fibonacci
def fib(n):
    a, b = 0, 1
    for _ in range(n):
        a, b = b, a + b
    return a}
    ],
    [
      'bash', q{#!/bin/sh
set -eu
for f in *.txt; do
    grep -i "TODO" "$f" || true
done}
    ],
    [
      'perl', q{use strict;
my @primes = grep { !($_ % 2) } 2..50;
print join(',', @primes), "\n";}
    ],
  );
  my @bits;
  push @bits, qq{<h2>token classes</h2>};
  push @bits,
    qq{<table class="cms-table"><thead><tr><th>class</th><th>swatch</th></tr></thead><tbody>};
  for my $c (@cls) {
    push @bits,
      qq{<tr><td><code>hl-$c</code></td><td><pre class="hl"><code><span class="hl-$c">sample text $c</span></code></pre></td></tr>};
  }
  push @bits, qq{</tbody></table>};
  push @bits, qq{<h2>code samples</h2>};
  for my $s (@samples) {
    my ($lang, $code) = @$s;
    my $hl = Iczelia::Highlight::highlight($code, $lang);
    push @bits, qq{<h3>$lang</h3>};
    push @bits, $hl;
  }
  push @bits, qq{<h2>inside a blockquote</h2>};
  push @bits,
    qq{<blockquote><p>quoted text with <code>inline code</code> in the middle &mdash; the inline-code rule is italic by default; check it doesn't fight the box.</p>};
  push @bits,
    Iczelia::Highlight::highlight(q{int x = 1; /* in a quote */}, 'c');
  push @bits, qq{</blockquote>};

  my $vars = $ctx->{render}->base_vars(
    title     => 'iczelia :: theme preview',
    page      => {is_admin_preview => 1},
    body_html => join('', @bits),
  );

  # Inherit the public page layout so the theme CSS actually applies.
  return Iczelia::HTTP::html(
    $ctx->{template}->render('views/theme_preview.tpl', $vars));
}

sub _preview {
  my ($ctx, $req) = @_;

  # Preview shares one per-session token across every admin form, so
  # we verify the token but skip the form_name binding.
  my $tok      = $req->{params}{csrf} // '';
  my $expected = $ctx->{auth}->csrf_token($req->{auth_sid}, 'preview');
  return Iczelia::HTTP::error(400, 'csrf')
    unless $tok eq $expected;
  my $body = $req->{params}{body} // '';
  my ($html, $math) = Iczelia::Markup::render($body);
  if ($ctx->{render}->{tex}) {
    $html =~ s{__MATH(\d+)__}{
            my $m = $math->[$1];
            $m ? $ctx->{render}->{tex}->render(@$m) : ''
        }ge;
  }
  return Iczelia::HTTP::html($html);
}

my %ALLOWED_IMG_CT = (
  'image/png'  => 'png',
  'image/jpeg' => 'jpg',
  'image/gif'  => 'gif',
  'image/webp' => 'webp',
);

sub _media_list {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{db}->all(
    q{SELECT id, filename, orig_name, content_type, size, sha256,
                 uploaded_at, thumb_filename
          FROM media ORDER BY uploaded_at DESC LIMIT 200}
  );
  my $sid = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{url} = '/media/' . $r->{filename};
    $r->{thumb_url} =
      $r->{thumb_filename}
      ? '/media/' . $r->{thumb_filename}
      : $r->{url};
    $r->{date_fmt} = _ts_fmt($r->{uploaded_at});
    $r->{size_kb}  = sprintf('%.0f', ($r->{size} || 0) / 1024);
    $r->{csrf_del} = $ctx->{auth}->csrf_token($sid, "media:del:$r->{id}");
  }
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_media.tpl',
      _admin_vars($ctx, $req, title => 'media', items => $rows)
    )
  );
}

sub _media_upload {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'upload');
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
  my $dir  = $ctx->{cfg}{'media-dir'};
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

  $ctx->{db}->do_(
    q{INSERT OR IGNORE INTO media
            (filename, orig_name, content_type, size, sha256, uploaded_at, thumb_filename)
          VALUES(?, ?, ?, ?, ?, strftime('%s','now'), ?)},
    $name, $f->{filename}, $ct, $f->{size}, $sha, $thumb_filename
  );

  return _json_ok({url => "/media/$name", filename => $name});
}

sub _media_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = _csrf_or_400($ctx, $req, "media:del:$id");
  return $err if $err;
  my $row = $ctx->{db}
    ->row('SELECT filename, thumb_filename FROM media WHERE id=?', $id);
  if ($row) {
    my $dir = $ctx->{cfg}{'media-dir'};

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
  $ctx->{db}->do_('DELETE FROM media WHERE id=?', $id);
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

sub _pgp_path {
  my ($ctx) = @_;
  require Iczelia::Handlers::Static;
  return Iczelia::Handlers::Static::_var_dir_of($ctx->{cfg}) . '/pub.pgp';
}

sub _pgp_form {
  my ($ctx, $req) = @_;
  my $sid   = $req->{auth_sid};
  my $path  = _pgp_path($ctx);
  my $size  = -e $path ? (-s $path)      : 0;
  my $mtime = -e $path ? (stat $path)[9] : 0;

  my @bits;
  push @bits,
    '<p>The key uploaded here is served at <code>/pub.pgp</code> with content-type <code>application/pgp-keys</code>.</p>';
  if ($size) {
    push @bits, sprintf '<p>Currently installed: %d bytes, uploaded %s.</p>',
      $size, _ts_fmt($mtime);
  }
  else {
    push @bits,
      '<p>No key installed. <code>/pub.pgp</code> currently 404s.</p>';
  }
  push @bits, '<p><label>Upload a new key (.pgp / .asc / armored text)<br>'
    . '<input type="file" name="file" accept=".pgp,.asc,application/pgp-keys,text/plain" required></label></p>';

  my $body =
    '<form class="cms-form" method="POST" action="/admin/pgp/" enctype="multipart/form-data">'
    . '<input type="hidden" name="csrf" value="'
    . $ctx->{auth}->csrf_token($sid, 'pgp') . '">'
    . join('', @bits)
    . '<p class="cms-actions"><button type="submit" class="cms-btn cms-btn-primary">upload</button></p>'
    . '</form>';
  if ($size) {
    $body .=
      '<form class="cms-form" method="POST" action="/admin/pgp/delete" onsubmit="return confirm(\'remove the installed PGP key?\')">'
      . '<input type="hidden" name="csrf" value="'
      . $ctx->{auth}->csrf_token($sid, 'pgp:delete') . '">'
      . '<p class="cms-actions"><button type="submit" class="cms-btn cms-btn-danger">remove key</button></p>'
      . '</form>';
  }

  return Iczelia::HTTP::html(
    _simple_form_render_html(
      $ctx, $req,
      title => 'pgp public key',
      body  => $body,
    )
  );
}

sub _pgp_upload {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'pgp');
  return $err if $err;

  my @files = @{$req->{uploads} || []};
  return Iczelia::HTTP::error(400, 'no file') unless @files;
  my $f = $files[0];

  return Iczelia::HTTP::error(413, 'too large') if $f->{size} > PGP_BODY_MAX;

  # Accept ASCII-armoured text or any >= 8-byte binary blob; we don't
  # do cryptographic validation - just enough to refuse zero-byte files.
  my $body = $f->{body} // '';
  return Iczelia::HTTP::error(400, 'empty') unless length $body >= 8;

  my $path = _pgp_path($ctx);
  my $dir  = $path;
  $dir =~ s{[^/]+\z}{};
  if ($dir && !-d $dir) {
    require File::Path;
    File::Path::make_path($dir);
  }
  my $tmp = "$path.tmp.$$";
  open my $fh, '>:raw', $tmp or return Iczelia::HTTP::error(500, "write: $!");
  print $fh $body;
  close $fh;
  rename $tmp, $path or do {
    unlink $tmp;
    return Iczelia::HTTP::error(500, "rename: $!");
  };
  return Iczelia::HTTP::redirect('/admin/pgp/');
}

sub _pgp_delete {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'pgp:delete');
  return $err if $err;
  my $path = _pgp_path($ctx);
  unlink $path if -e $path;
  return Iczelia::HTTP::redirect('/admin/pgp/');
}

# Render an arbitrary <body> string inside the admin chrome (caller
# already supplied its own <form>). Used by ad-hoc admin pages.
sub _simple_form_render_html {
  my ($ctx, $req, %arg) = @_;
  my $vars = _admin_vars($ctx, $req, title => $arg{title});
  $vars->{form_action} = '';
  $vars->{form_csrf}   = '';
  $vars->{form_body} =
      '<div class="cms-edit-head"><h1>'
    . escape_html($arg{title})
    . '</h1></div>'
    . $arg{body};
  return $ctx->{template}->render('views/admin_pgp.tpl', $vars);
}

# Render an inputs-only form body inside the admin chrome (the chrome
# wraps it in <form>). Used by updates / webring / settings.
sub _simple_form_render {
  my ($ctx, $req, %arg) = @_;
  my $vars = _admin_vars($ctx, $req, title => $arg{title});
  $vars->{form_action} = $arg{action};
  $vars->{form_csrf}   = $arg{csrf};
  $vars->{form_body}   = $arg{body};
  return $ctx->{template}->render('views/admin_simple_form.tpl', $vars);
}

sub _dynamic_list {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{content}->list_dynamic_pages;
  my $sid  = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{updated_fmt} = _ts_fmt($r->{updated_at});
    $r->{csrf_del}    = $ctx->{auth}->csrf_token($sid, "dynpage:del:$r->{id}");
  }
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_dynamic_list.tpl',
      _admin_vars(
        $ctx, $req,
        title => 'dynamic pages',
        pages => $rows,
      )
    )
  );
}

sub _dynamic_template_options {
  my ($ctx) = @_;

  # Add an entry here for each <name>.tpl + <name>.json pair under
  # share/templates that the admin form should expose.
  return [{name => 'generic', label => 'generic (markdown body)'},];
}

sub _render_dynamic_form {
  my ($ctx, $req, $row, %opt) = @_;
  my $sid       = $req->{auth_sid};
  my $form_name = $row ? "dynpage:$row->{id}" : 'dynpage:new';
  my $action =
    $row
    ? "/admin/dynamic/$row->{id}/edit"
    : '/admin/dynamic/new';
  my $tpl_opts    = _dynamic_template_options($ctx);
  my $current_tpl = $row ? $row->{template} : ($opt{template} || 'generic');

  my $schema = $ctx->{schema}->load($current_tpl);
  my $data;
  if ($row) {
    $data = $ctx->{schema}->decode($row->{data});
  }
  else {
    $data = {};
  }

  # On a re-display after a validation error, prefer the user's
  # in-flight params over the persisted row.
  if ($opt{params}) {
    my ($parsed) = $ctx->{schema}->parse_form($current_tpl, $opt{params});
    $data = $parsed if $parsed;
  }

  my @field_html;
  for my $f (@{$schema->{fields}}) {
    my $val = $data->{$f->{name}};
    push @field_html, _field_for_form($f, $val);
  }

  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_dynamic_edit.tpl',
      _admin_vars(
        $ctx, $req,
        title         => $row ? "edit $row->{route}" : 'new dynamic page',
        row           => $row,
        form_action   => $action,
        csrf_form     => $ctx->{auth}->csrf_token($sid, $form_name),
        template_opts => $tpl_opts,
        current_tpl   => $current_tpl,
        schema        => $schema,
        fields_html   => \@field_html,
        error         => $opt{error},
        route_value   => ($opt{params}{route} // ($row ? $row->{route} : '/')),
        title_value   => ($opt{params}{title} // ($row ? $row->{title} : '')),
      )
    )
  );
}

sub _dynamic_new {
  my ($ctx, $req) = @_;
  return _render_dynamic_form($ctx, $req, undef);
}

sub _dynamic_edit {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $row = $ctx->{content}->get_dynamic_page($id)
    or return Iczelia::HTTP::error(404);
  return _render_dynamic_form($ctx, $req, $row);
}

sub _dynamic_create {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'dynpage:new');
  return $err if $err;
  my $tpl = $req->{params}{template} || 'generic';
  my ($data, $errs) = $ctx->{schema}->parse_form($tpl, $req->{params});
  my $data_json = $ctx->{schema}->encode($data);
  my ($id, $why) = $ctx->{content}->create_dynamic_page(
    {
      route    => $req->{params}{route},
      title    => $req->{params}{title},
      template => $tpl,
      data     => $data_json,
    }
  );
  if (!$id) {
    return _render_dynamic_form(
      $ctx, $req, undef,
      error    => $why,
      params   => $req->{params},
      template => $tpl
    );
  }
  return Iczelia::HTTP::redirect("/admin/dynamic/$id/edit");
}

sub _dynamic_update {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = _csrf_or_400($ctx, $req, "dynpage:$id");
  return $err if $err;
  my $cur = $ctx->{content}->get_dynamic_page($id)
    or return Iczelia::HTTP::error(404);
  my $tpl = $req->{params}{template} || $cur->{template};
  my ($data, $errs) = $ctx->{schema}->parse_form($tpl, $req->{params});
  my $data_json = $ctx->{schema}->encode($data);
  my ($_id, $why) = $ctx->{content}->update_dynamic_page(
    $id,
    {
      route    => $req->{params}{route},
      title    => $req->{params}{title},
      template => $tpl,
      data     => $data_json,
    }
  );

  if ($why) {
    return _render_dynamic_form(
      $ctx, $req, $cur,
      error    => $why,
      params   => $req->{params},
      template => $tpl
    );
  }
  return Iczelia::HTTP::redirect("/admin/dynamic/$id/edit");
}

sub _dynamic_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = _csrf_or_400($ctx, $req, "dynpage:del:$id");
  return $err if $err;
  $ctx->{content}->delete_dynamic_page($id);
  return Iczelia::HTTP::redirect('/admin/dynamic/');
}

sub _lang_list {
  my ($ctx, $req) = @_;
  my $rows = $ctx->{content}->list_langs;
  my $sid  = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{updated_fmt} = _ts_fmt($r->{updated_at});
    $r->{csrf_del}    = $ctx->{auth}->csrf_token($sid, "lang:del:$r->{id}");
  }
  my @builtins = Iczelia::Highlight::languages();
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_highlight_list.tpl',
      _admin_vars(
        $ctx, $req,
        title        => 'highlighter languages',
        langs        => $rows,
        builtins_str => join(', ', @builtins),
      )
    )
  );
}

sub _render_lang_form {
  my ($ctx, $req, $row, %opt) = @_;
  my $sid       = $req->{auth_sid};
  my $form_name = $row ? "lang:$row->{id}" : 'lang:new';
  my $action =
    $row
    ? "/admin/highlight/$row->{id}/edit"
    : '/admin/highlight/new';
  my $rec = $opt{params}
    || (
    $row
    ? {
      name          => $row->{name},
      aliases       => $row->{aliases},
      keywords      => $row->{keywords},
      types         => $row->{types},
      builtins      => $row->{builtins},
      line_comment  => $row->{line_comment},
      block_comment => $row->{block_comment},
      string_quotes => $row->{string_quotes},
    }
    : {
      name          => '',
      aliases       => '',
      keywords      => '',
      types         => '',
      builtins      => '',
      line_comment  => '',
      block_comment => '',
      string_quotes => '"',
    }
    );
  return Iczelia::HTTP::html(
    $ctx->{template}->render(
      'views/admin_highlight_edit.tpl',
      _admin_vars(
        $ctx, $req,
        title       => $row ? "edit $row->{name}" : 'new language',
        row         => $row,
        form_action => $action,
        csrf_form   => $ctx->{auth}->csrf_token($sid, $form_name),
        error       => $opt{error},
        rec         => $rec,
      )
    )
  );
}

sub _lang_new {
  my ($ctx, $req) = @_;
  return _render_lang_form($ctx, $req, undef);
}

sub _lang_edit {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $row = $ctx->{content}->get_lang($id)
    or return Iczelia::HTTP::error(404);
  return _render_lang_form($ctx, $req, $row);
}

sub _lang_create {
  my ($ctx, $req) = @_;
  my $err = _csrf_or_400($ctx, $req, 'lang:new');
  return $err if $err;
  my ($id, $why) = $ctx->{content}->create_lang($req->{params});
  if (!$id) {
    return _render_lang_form(
      $ctx, $req, undef,
      error  => $why,
      params => $req->{params}
    );
  }
  return Iczelia::HTTP::redirect("/admin/highlight/$id/edit");
}

sub _lang_update {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = _csrf_or_400($ctx, $req, "lang:$id");
  return $err if $err;
  my $cur = $ctx->{content}->get_lang($id)
    or return Iczelia::HTTP::error(404);
  my ($_id, $why) = $ctx->{content}->update_lang($id, $req->{params});
  if ($why) {
    return _render_lang_form(
      $ctx, $req, $cur,
      error  => $why,
      params => $req->{params}
    );
  }
  return Iczelia::HTTP::redirect("/admin/highlight/$id/edit");
}

sub _lang_delete {
  my ($ctx, $req) = @_;
  my $id  = $req->{caps}{id} + 0;
  my $err = _csrf_or_400($ctx, $req, "lang:del:$id");
  return $err if $err;
  $ctx->{content}->delete_lang($id);
  return Iczelia::HTTP::redirect('/admin/highlight/');
}

1;
