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

package Iczelia::Handlers::Admin::Posts;
use strict;
use warnings;
use Iczelia::HTTP    ();
use Iczelia::Util    ();
use Iczelia::Time    qw(ts_fmt ts_to_local_input);
use Iczelia::Content ();

use constant POST_BODY_MAX => 256 * 1024;
use constant TITLE_MAX     => 200;
use constant TAGS_MAX      => 200;

sub register {
  my ($class, $router, $ctx) = @_;
  my $gate = $ctx->auth->route_gate($ctx);
  for my $kind (qw(blog journal)) {
    $router->get("/admin/$kind/",           $gate->(\&_post_list,         $kind));
    $router->get("/admin/$kind/new",        $gate->(\&_post_new,          $kind));
    $router->post("/admin/$kind/new",       $gate->(\&_post_create,       $kind));
    $router->get("/admin/$kind/:slug/edit", $gate->(\&_post_edit,         $kind));
    $router->post("/admin/$kind/:slug/edit",  $gate->(\&_post_update,     $kind));
    $router->post("/admin/$kind/:slug/delete",$gate->(\&_post_delete,     $kind));
    $router->get("/admin/$kind/:slug/revisions",
      $gate->(\&_revisions_list, $kind));
    $router->get("/admin/$kind/:slug/revisions/:rev",
      $gate->(\&_revisions_view, $kind));
    $router->post("/admin/$kind/:slug/revisions/:rev/restore",
      $gate->(\&_revisions_restore, $kind));
    $router->post("/admin/$kind/:slug/aliases/:from/delete",
      $gate->(\&_alias_delete, $kind));
  }
}

sub _post_list {
  my ($ctx, $req, $kind) = @_;
  my $posts = $ctx->content->list_posts($kind);
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_post_list.tpl',
    title => "$kind posts",
    kind  => $kind,
    posts => $posts,
  );
}

sub _post_new {
  my ($ctx, $req, $kind) = @_;
  return _render_post_form($ctx, $req, $kind, undef);
}

sub _post_edit {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $post = $ctx->content->get_post($kind, $slug)
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
    my $rows = $ctx->content->list_aliases($post->{id});
    for my $a (@$rows) {
      push @$aliases,
        {
        from_slug => $a->{from_slug},
        csrf_del  => $ctx->auth
          ->csrf_token($sid, "alias-del:$kind:$post->{slug}:$a->{from_slug}"),
        };
    }
  }
  my $rec = {
    id             => 0,
    slug           => '',
    title          => '',
    date           => ts_fmt(time),
    tags           => '',
    body           => '',
    draft          => 0,
    publish_at     => undef,
    publish_at_fmt => '',
    word_count     => 0,
    aliases        => $aliases,
  };
  if ($post) {
    %$rec = (
      %$rec, %$post,
      publish_at_fmt => ts_to_local_input($post->{publish_at}),
      updated_fmt    => ts_fmt($post->{updated_at}),
      word_count     => $post->{word_count} // 0,
      aliases        => $aliases,
    );
  }

  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_edit_post.tpl',
    title       => $post ? "edit $kind/$post->{slug}" : "new $kind",
    kind        => $kind,
    post        => $rec,
    form_action => $action,
    csrf_form   => $ctx->auth->csrf_token($sid, $form_name),
  );
}

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

  # publish_at: past timestamps are almost always a typo for `date`.
  my $pub_in = $p->{publish_at} // '';
  my $publish_at;
  if (length $pub_in) {
    $publish_at = Iczelia::Content::Posts::normalize_publish_at($pub_in);
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
  my $err = $ctx->auth->require_csrf($req, "post-new:$kind");
  return $err if $err;
  my ($rec, $why) = _validate_post($req->{params}, undef);
  return Iczelia::HTTP::error(400, $why) unless $rec;
  my $slug = $ctx->content->create_post($kind, $rec);
  return Iczelia::HTTP::redirect("/admin/$kind/$slug/edit");
}

sub _post_update {
  my ($ctx, $req, $kind) = @_;
  my $old = $req->{caps}{slug};
  my $err = $ctx->auth->require_csrf($req, "post:$kind:$old");
  return $err if $err;
  my ($rec, $why) = _validate_post($req->{params}, $old);
  return Iczelia::HTTP::error(400, $why) unless $rec;
  $rec->{author} = $req->{auth_user};
  my $new = $ctx->content->update_post($kind, $old, $rec);
  return Iczelia::HTTP::redirect("/admin/$kind/$new/edit");
}

sub _post_delete {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $err  = $ctx->auth->require_csrf($req, "post:$kind:$slug");
  return $err if $err;
  $ctx->content->delete_post($kind, $slug);
  return Iczelia::HTTP::redirect("/admin/$kind/");
}

sub _revisions_list {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $post = $ctx->content->get_post($kind, $slug)
    or return Iczelia::HTTP::error(404);
  my $rows = $ctx->content->list_revisions($post->{id});
  my $sid = $req->{auth_sid};
  for my $r (@$rows) {
    $r->{created_fmt}  = ts_fmt($r->{created_at});
    $r->{csrf_restore} = $ctx->auth
      ->csrf_token($sid, "rev-restore:$kind:$slug:$r->{revision_num}");
  }
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_post_revisions.tpl',
    title     => "$kind/$slug revisions",
    kind      => $kind,
    slug      => $slug,
    post      => $post,
    revisions => $rows,
  );
}

sub _revisions_view {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $rev  = $req->{caps}{rev} + 0;
  my $post = $ctx->content->get_post($kind, $slug)
    or return Iczelia::HTTP::error(404);
  my $row = $ctx->content->get_revision($post->{id}, $rev);
  return Iczelia::HTTP::error(404) unless $row;
  my $sid = $req->{auth_sid};
  $row->{created_fmt} = ts_fmt($row->{created_at});
  return Iczelia::Handlers::Admin::render_admin(
    $ctx, $req, 'admin_post_revision_view.tpl',
    title        => "$kind/$slug rev $rev",
    kind         => $kind,
    slug         => $slug,
    post         => $post,
    rev          => $row,
    csrf_restore => $ctx->auth->csrf_token($sid, "rev-restore:$kind:$slug:$rev"),
  );
}

sub _revisions_restore {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  my $rev  = $req->{caps}{rev} + 0;
  my $err  =
    $ctx->auth->require_csrf($req, "rev-restore:$kind:$slug:$rev");
  return $err if $err;
  my $post = $ctx->content->get_post($kind, $slug)
    or return Iczelia::HTTP::error(404);
  my $row = $ctx->content->get_revision($post->{id}, $rev);
  return Iczelia::HTTP::error(404) unless $row;

  # Restore is itself a save: the restored body becomes the next
  # revision so the original history is preserved.
  my $new_slug = $ctx->content->update_post(
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
  my $err  =
    $ctx->auth->require_csrf($req, "alias-del:$kind:$slug:$from");
  return $err if $err;
  $ctx->content->delete_alias($kind, $from);
  return Iczelia::HTTP::redirect("/admin/$kind/$slug/edit");
}

1;
