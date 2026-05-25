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

package Iczelia::Handlers::Git;
use strict;
use warnings;
use Encode               ();
use Iczelia              ();
use Iczelia::HTTP        ();
use Iczelia::Git         ();
use Iczelia::Subpages    ();
use Iczelia::Highlight   ();
use Iczelia::Markup      ();
use Iczelia::Util        qw(escape_html escape_url);

# Public cgit-style read-only browser. All pages render via the
# layouts/page.tpl chrome (iczelia logo, vert.jpg, dark theme,
# Arial body + LM Mono code + text-shadow halo), with per-route
# content built as a string and threaded through views/git_page.tpl.
# The site is dark-only so there's no theme toggle here -- the only
# visitor preferences are tab-size and blob word-wrap.

use constant {
  LOG_PAGE_SIZE       => 30,
  RAW_MAX_BYTES       => 16 * 1024 * 1024,
  BLOB_VIEW_MAX_BYTES => 1 * 1024 * 1024,
  README_MAX_BYTES    => 65536,
  REF_SUMMARY_LIMIT   => 16,
  TAB_COOKIE          => 'iczelia_tab',
  WRAP_COOKIE         => 'iczelia_wrap',
  DEFAULT_TAB         => 2,
  DEFAULT_WRAP        => 0,
};

my @TAB_SIZES = (2, 4, 8);

sub register {
  my ($class, $router, $ctx) = @_;
  $router->get('/git/',                  sub { _index($ctx, $_[0])   });
  $router->get('/git/:slug/',            sub { _summary($ctx, $_[0]) });
  $router->get('/git/:slug/log/',        sub { _log($ctx, $_[0])     });
  $router->get('/git/:slug/branches/',   sub { _refs($ctx, $_[0], 'branch') });
  $router->get('/git/:slug/tags/',       sub { _refs($ctx, $_[0], 'tag') });
  $router->get('/git/:slug/tree/',       sub { _tree($ctx, $_[0], '') });
  $router->get('/git/:slug/tree/*path',  sub { _tree($ctx, $_[0], $_[0]->{caps}{path}) });
  $router->get('/git/:slug/blob/*path',  sub { _blob($ctx, $_[0])    });
  $router->get('/git/:slug/raw/*path',   sub { _raw($ctx, $_[0])     });
  $router->get('/git/:slug/commit/:sha', sub { _commit($ctx, $_[0])  });
}

sub _var_dir {
  my ($ctx) = @_;
  my $tmp = $ctx->cfg->{'tmp-dir'};
  return $tmp if !defined $tmp;
  (my $var = $tmp) =~ s{/tmp/?\z}{};
  return $var;
}

# Tab-size preference. Cookie value 2/4/8 (anything else -> default).
sub _tab_size {
  my ($req) = @_;
  my $v = $req && $req->{cookies} && $req->{cookies}{+TAB_COOKIE};
  return DEFAULT_TAB unless defined $v;
  for my $n (@TAB_SIZES) { return $n if "$v" eq "$n" }
  return DEFAULT_TAB;
}

sub _wrap_enabled {
  my ($req) = @_;
  my $v = $req && $req->{cookies} && $req->{cookies}{+WRAP_COOKIE};
  return DEFAULT_WRAP unless defined $v;
  return $v =~ /^(?:1|on|true)$/ ? 1 : 0;
}

sub _wanted_tab {
  my ($req) = @_;
  my $v = $req && $req->{qparams} && $req->{qparams}{'set-tab'};
  return undef unless defined $v;
  return 'reset' if $v eq 'default';
  for my $n (@TAB_SIZES) { return $n if "$v" eq "$n" }
  return undef;
}

sub _wanted_wrap {
  my ($req) = @_;
  my $v = $req && $req->{qparams} && $req->{qparams}{'set-wrap'};
  return undef unless defined $v;
  return 'reset' if $v eq 'default';
  return 1 if $v =~ /^(?:1|on|true)$/;
  return 0 if $v =~ /^(?:0|off|false)$/;
  return undef;
}

sub _set_cookie_pref {
  my ($req, $name, $value) = @_;
  my %c = (name => $name, path => '/', samesite => 'Lax');
  if ($value eq 'reset') { $c{value} = ''; $c{max_age} = 0 }
  else                   { $c{value} = "$value"; $c{max_age} = 60 * 60 * 24 * 365 }
  $c{secure} = 1 if Iczelia::HTTP::is_https($req);
  my $resp = Iczelia::HTTP::redirect($req->{path}, status => 303);
  $resp->{cookies}   = [Iczelia::HTTP::make_cookie(%c)];
  $resp->{_no_cache} = 1;
  return $resp;
}

# Look up the repo row and on-disk path. Returns ($row, $path, $why);
# $why is undef on success, '404' for no such repo, 'nogit' when the
# git binary isn't on PATH, 'empty' when the bare repo isn't on disk.
sub _open {
  my ($ctx, $slug) = @_;
  return (undef, undef, '404')
    unless defined $slug && $slug =~ /^[a-z0-9][a-z0-9-]*\z/;
  my $row = $ctx->db->row('SELECT * FROM git_repos WHERE slug=?', $slug);
  return (undef, undef, '404') unless $row;
  return ($row, undef, 'nogit') unless Iczelia::Git::available();
  my $path = eval { Iczelia::Git::bare_repo_path(_var_dir($ctx), $slug) };
  return ($row, undef, 'badpath') unless defined $path;
  return ($row, undef, 'empty')   unless -d "$path/objects";
  return ($row, $path, undef);
}

# Render a built content string through views/git_page.tpl + the
# git layout. Vars consumed by layouts/git.tpl:
#   git_repo_slug     - slug of the repo we're on (undef on /git/)
#   tab_summary_on    - truthy when the summary tab is active
#   tab_log_on        - same for log
#   tab_tree_on       - same for tree
#   tab_size_css      - extra <style> emitting tab-size: <N>
#   git_content       - raw HTML for the main column
sub _render {
  my ($ctx, $title, $content, $tab, @rest) = @_;
  my $wrap = DEFAULT_WRAP;
  $wrap = shift @rest if @rest % 2;
  my %opt = @rest;
  $tab = DEFAULT_TAB unless defined $tab && $tab =~ /^\d+$/;
  $wrap = DEFAULT_WRAP unless defined $wrap;
  my $tab_css = ".hl, .git-lines td.lc { -moz-tab-size: $tab; tab-size: $tab; }";
  if ($wrap) {
    $tab_css .= "\n.git-lines td.lc pre { white-space: pre-wrap; "
      . "word-wrap: break-word; overflow-wrap: anywhere; }";
  }

  my $active = delete $opt{active_tab} // '';
  my $slug   = delete $opt{repo_slug};

  my $vars = $ctx->render->base_vars(
    title          => $title,
    git_content    => $content,
    tab_size_css   => $tab_css,
    git_repo_slug  => $slug,
    tab_summary_on => ($active eq 'summary' ? 1 : 0),
    tab_log_on     => ($active eq 'log'     ? 1 : 0),
    tab_tree_on    => ($active eq 'tree'    ? 1 : 0),
    %opt,
  );
  my $html = $ctx->template->render('views/git_page.tpl', $vars);
  my $resp = Iczelia::HTTP::html($html, %{$opt{headers} || {}});
  $resp->{headers}{Vary}            //= 'Cookie';
  $resp->{headers}{'Cache-Control'} //= 'no-store';
  $resp->{_no_cache} = 1;
  return $resp;
}

# Short-circuit ?set-tab=... in every public route.
sub _route {
  my ($ctx, $req, $build) = @_;
  if (defined(my $want = _wanted_tab($req))) {
    return _set_cookie_pref($req, TAB_COOKIE, $want);
  }
  if (defined(my $want = _wanted_wrap($req))) {
    return _set_cookie_pref($req, WRAP_COOKIE, $want);
  }
  return $build->(_tab_size($req), _wrap_enabled($req));
}

sub _index {
  my ($ctx, $req) = @_;
  return _route($ctx, $req, sub {
    my ($tab) = @_;
    my $rows = $ctx->db->all(
      q{SELECT slug, title, owner, description,
                  last_pulled_at, head_sha, updated_at
            FROM git_repos ORDER BY slug}
    );
    my @body;
    push @body, '<section class="ab-section">';
    push @body, '<h1 class="ab-h1">:: git :: repositories</h1>';
    if (!@$rows) {
      push @body, '<p class="empty">no repositories.</p>';
    }
    else {
      push @body,
        '<table class="git-listing"><thead><tr>'
      . '<th>name</th><th>owner</th><th>description</th>'
      . '<th class="mtime">last update</th></tr></thead><tbody>';
      for my $r (@$rows) {
        my $when = _fmt_git_time(
          $r->{last_pulled_at} || $r->{updated_at}
        );
        my $title = length($r->{title}) ? $r->{title} : $r->{slug};
        push @body, sprintf(
          '<tr><td><a href="/git/%s/">%s</a></td>'
          . '<td>%s</td><td>%s</td><td class="mtime">%s</td></tr>',
          escape_url($r->{slug}),
          escape_html($title),
          escape_html(length $r->{owner} ? $r->{owner} : '-'),
          escape_html($r->{description} // ''),
          $when,
        );
      }
      push @body, '</tbody></table>';
    }
    push @body, '</section>';
    push @body, _tab_prefs($tab);
    return _render($ctx, 'iczelia :: git', join("\n", @body), $tab,
      repo_slug => undef);
  });
}

sub _summary {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  return _route($ctx, $req, sub {
    my ($tab, $wrap) = @_;
    my ($row, $path, $why) = _open($ctx, $slug);
    return _not_found($ctx, $tab) if $why && $why eq '404';
    if ($why && $why ne 'empty') { return _empty($ctx, $row, $tab, $why) }
    my $log  = $path ? (Iczelia::Git::log($path, limit => 10) || []) : [];
    my $br   = $path ? (Iczelia::Git::branches($path) || []) : [];
    my $tg   = $path ? (Iczelia::Git::tags($path) || []) : [];
    my $rdm  = $path ? _readme_html($path, $row->{slug}) : '';

    my @out;
    push @out, '<section class="ab-section">';
    push @out, sprintf('<h1 class="ab-h1">:: %s</h1>',
      escape_html(length $row->{title} ? $row->{title} : $row->{slug}));
    push @out, '<p class="git-owner">' . escape_html($row->{owner}) . '</p>'
      if length $row->{owner};
    push @out, '<p class="git-desc">' . escape_html($row->{description})
      . '</p>' if length $row->{description};
    push @out, '</section>';

    push @out, '<div class="ab-rule"></div>';
    push @out, '<section class="ab-section">';
    push @out, '<h2 class="ab-h2">recent commits</h2>';
    if (@$log) {
      push @out, '<table class="git-log"><tbody>';
      for my $c (@$log) {
        push @out, sprintf('<tr><td class="mtime">%s</td>'
          . '<td><a href="/git/%s/commit/%s">%s</a></td>'
          . '<td class="size">%s</td></tr>',
          _fmt_git_time($c->{ts}),
          escape_url($row->{slug}), $c->{sha},
          escape_html($c->{subject}), escape_html($c->{author}));
      }
      push @out, '</tbody></table>';
    }
    else {
      push @out, '<p class="empty">no commits yet.</p>';
    }
    push @out, '</section>';

    push @out, '<div class="ab-rule"></div>';
    push @out, '<section class="ab-section">';
    push @out, '<h2 class="ab-h2">branches</h2>';
    push @out, _ref_table($row->{slug}, $br, 'branch',
      limit => REF_SUMMARY_LIMIT,
      all_href => "/git/" . escape_url($row->{slug}) . "/branches/");
    push @out, '<h2 class="ab-h2">tags</h2>';
    push @out, _ref_table($row->{slug}, $tg, 'tag',
      limit => REF_SUMMARY_LIMIT,
      all_href => "/git/" . escape_url($row->{slug}) . "/tags/");
    push @out, '</section>';

    if (length $rdm) {
      push @out, '<div class="ab-rule"></div>';
      push @out, '<section class="ab-section">';
      push @out, $rdm;
      push @out, '</section>';
    }

    push @out, _tab_prefs($tab);

    my $title = "iczelia :: git :: " .
      (length $row->{title} ? $row->{title} : $row->{slug});
    return _render($ctx, $title, join("\n", @out), $tab,
      repo_slug => $row->{slug}, active_tab => 'summary');
  });
}

sub _refs {
  my ($ctx, $req, $kind) = @_;
  my $slug = $req->{caps}{slug};
  return _route($ctx, $req, sub {
    my ($tab, $wrap) = @_;
    my ($row, $path, $why) = _open($ctx, $slug);
    return _not_found($ctx, $tab) if $why && $why eq '404';
    if ($why && $why ne 'empty') { return _empty($ctx, $row, $tab, $why) }
    my $refs = [];
    if ($path) {
      $refs = $kind eq 'branch'
        ? (Iczelia::Git::branches($path) || [])
        : (Iczelia::Git::tags($path) || []);
    }

    my $plural = $kind eq 'branch' ? 'branches' : 'tags';
    my @out;
    push @out, '<section class="ab-section">';
    push @out, sprintf('<h1 class="ab-h1">:: %s :: %s</h1>',
      escape_html($row->{slug}), escape_html($plural));
    push @out, _ref_table($row->{slug}, $refs, $kind);
    push @out, '</section>';
    push @out, _tab_prefs($tab);
    return _render($ctx, "iczelia :: git :: $row->{slug} :: $plural",
      join("\n", @out), $tab,
      repo_slug => $row->{slug}, active_tab => 'summary');
  });
}

sub _log {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $page = ($req->{qparams}{page} // '') =~ /^(\d+)$/ ? $1 + 0 : 1;
  $page = 1 if $page < 1;
  my $ref  = $req->{qparams}{h};
  $ref = undef unless defined $ref && $ref =~ m{^[A-Za-z0-9._/\-]+\z};
  return _route($ctx, $req, sub {
    my ($tab) = @_;
    my ($row, $path, $why) = _open($ctx, $slug);
    return _not_found($ctx, $tab) if $why && $why eq '404';
    if ($why && $why ne 'empty') { return _empty($ctx, $row, $tab, $why) }
    my $skip = ($page - 1) * LOG_PAGE_SIZE;
    my $rows = $path ? (Iczelia::Git::log($path,
      ref => $ref, limit => LOG_PAGE_SIZE + 1, skip => $skip) || []) : [];
    my $has_next = @$rows > LOG_PAGE_SIZE;
    pop @$rows if $has_next;

    my @out;
    push @out, '<section class="ab-section">';
    push @out, '<h1 class="ab-h1">:: log'
      . (defined $ref ? ' @ ' . escape_html($ref) : '') . '</h1>';
    if (@$rows) {
      push @out, '<table class="git-log"><thead><tr>'
        . '<th class="mtime">date</th><th>subject</th>'
        . '<th class="size">author</th><th class="size">commit</th>'
        . '</tr></thead><tbody>';
      for my $c (@$rows) {
        push @out, sprintf('<tr><td class="mtime">%s</td>'
          . '<td><a href="/git/%s/commit/%s">%s</a></td>'
          . '<td class="size">%s</td><td class="size">%s</td></tr>',
          _fmt_git_time($c->{ts}),
          escape_url($row->{slug}), $c->{sha},
          escape_html($c->{subject}),
          escape_html($c->{author}),
          escape_html($c->{short}));
      }
      push @out, '</tbody></table>';
      my @pager;
      push @pager, sprintf('<a href="/git/%s/log/?page=%d%s">&laquo; newer</a>',
        escape_url($row->{slug}), $page - 1,
        (defined $ref ? '&amp;h=' . escape_url($ref) : ''))
        if $page > 1;
      push @pager, sprintf('<a href="/git/%s/log/?page=%d%s">older &raquo;</a>',
        escape_url($row->{slug}), $page + 1,
        (defined $ref ? '&amp;h=' . escape_url($ref) : ''))
        if $has_next;
      push @out, '<p class="git-pager">' . join(' | ', @pager) . '</p>'
        if @pager;
    }
    else {
      push @out, '<p class="empty">no commits.</p>';
    }
    push @out, '</section>';
    push @out, _tab_prefs($tab);
    return _render($ctx,
      "iczelia :: git :: $row->{slug} :: log",
      join("\n", @out), $tab,
      repo_slug => $row->{slug}, active_tab => 'log');
  });
}

sub _tree {
  my ($ctx, $req, $path_in) = @_;
  my $slug = $req->{caps}{slug};
  $path_in //= '';
  my $clean = '';
  if (length $path_in) {
    my $san = Iczelia::Subpages::sanitize_rel_path($path_in);
    return Iczelia::HTTP::error(404) unless defined $san;
    $clean = $san;
  }
  return _route($ctx, $req, sub {
    my ($tab) = @_;
    my ($row, $path, $why) = _open($ctx, $slug);
    return _not_found($ctx, $tab) if $why && $why eq '404';
    if ($why && $why ne 'empty') { return _empty($ctx, $row, $tab, $why) }
    return _empty($ctx, $row, $tab, 'empty') unless $path;

    my $entries = Iczelia::Git::tree($path, 'HEAD', $clean) || [];
    my $head    = Iczelia::Git::head_sha($path);
    my %last;
    %last = %{ _last_commits_cached($ctx, $row, $path, $head, $clean) }
      if $head && @$entries;

    my @out;
    push @out, '<section class="ab-section">';
    push @out, '<h1 class="ab-h1">:: ' . _breadcrumb($row->{slug}, $clean) . '</h1>';

    push @out, '<table class="git-tree"><thead><tr>'
      . '<th></th><th>name</th><th class="size">size</th>'
      . '<th>Last commit</th><th class="mtime">date</th>'
      . '</tr></thead><tbody>';
    if (length $clean) {
      push @out, '<tr><td class="icon"><img src="/cms-icons/folder.png" alt=""></td>'
        . '<td><a href="../">..</a></td>'
        . '<td class="size">-</td><td>-</td><td class="mtime">-</td></tr>';
    }
    for my $e (@$entries) {
      my ($href, $disp, $size, $icon);
      if ($e->{type} eq 'dir') {
        $href = escape_url($e->{name}) . '/';
        $disp = escape_html($e->{name}) . '/';
        $size = '-';
        $icon = 'folder.png';
      }
      elsif ($e->{type} eq 'submodule') {
        $href = '#';
        $disp = escape_html($e->{name}) . '@';
        $size = '-';
        $icon = 'folder.png';
      }
      else {
        my $abs = sprintf('/git/%s/blob/%s',
          escape_url($row->{slug}),
          _join_url_path($clean, $e->{name}));
        $href = $abs;
        $disp = escape_html($e->{name});
        $size = defined $e->{size}
          ? Iczelia::Subpages::fmt_size($e->{size})
          : '-';
        my $rel = length $clean ? "$clean/$e->{name}" : $e->{name};
        my ($sniff) = Iczelia::Git::blob($path, 'HEAD', $rel,
          max_bytes => 8192);
        my $type = Iczelia::Subpages::detect_file_type($e->{name}, $sniff);
        $icon = $type->{icon};
      }
      my $lc    = $last{$e->{name}};
      my $cmsg  = $lc
        ? sprintf('<a href="/git/%s/commit/%s">%s</a>',
            escape_url($row->{slug}), $lc->{sha},
            escape_html($lc->{subject}))
        : '-';
      my $cwhen = $lc ? _fmt_git_time($lc->{ts}) : '-';
      push @out, sprintf('<tr><td class="icon"><img src="/cms-icons/%s" alt=""></td>'
        . '<td><a href="%s">%s</a></td>'
        . '<td class="size">%s</td><td>%s</td>'
        . '<td class="mtime">%s</td></tr>',
        escape_html($icon), $href, $disp, $size, $cmsg, $cwhen);
    }
    push @out, '</tbody></table>';
    push @out, '</section>';
    push @out, _tab_prefs($tab);

    my $title = "iczelia :: git :: $row->{slug} :: tree"
      . (length $clean ? "/$clean" : '');
    return _render($ctx, $title, join("\n", @out), $tab,
      repo_slug => $row->{slug}, active_tab => 'tree');
  });
}

sub _blob {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $path = $req->{caps}{path} // '';
  my $clean = Iczelia::Subpages::sanitize_rel_path($path);
  return Iczelia::HTTP::error(404) unless defined $clean;
  return _route($ctx, $req, sub {
    my ($tab, $wrap) = @_;
    my ($row, $rpath, $why) = _open($ctx, $slug);
    return _not_found($ctx, $tab) if $why && $why eq '404';
    if ($why && $why ne 'empty') { return _empty($ctx, $row, $tab, $why) }
    return _empty($ctx, $row, $tab, 'empty') unless $rpath;

    my ($bytes, $size, $sha) =
      Iczelia::Git::blob($rpath, 'HEAD', $clean,
        max_bytes => BLOB_VIEW_MAX_BYTES);
    return _not_found($ctx, $tab) unless defined $size;

    my $raw = sprintf('/git/%s/raw/%s',
      escape_url($row->{slug}), _join_url_path('', $clean));
    my $body_html;
    if (!defined $bytes) {
      $body_html = sprintf('<p class="empty">file is %s; '
        . '<a href="%s">view raw</a>.</p>',
        Iczelia::Subpages::fmt_size($size), $raw);
    }
    else {
      my $type = Iczelia::Subpages::detect_file_type($clean, $bytes);
      my $ct = $type->{content_type};
      if ($type->{is_binary}) {
        if ($ct =~ m{^image/(?:png|jpe?g|gif|webp)$} && $size <= 1_000_000) {
          $body_html = sprintf('<p class="binary">binary, %s; '
            . '<a href="%s">view raw</a>.</p>'
            . '<p><img class="git-img" src="%s" alt=""></p>',
            Iczelia::Subpages::fmt_size($size), $raw, $raw);
        }
        else {
          $body_html = sprintf('<p class="binary">binary file, %s; '
            . '<a href="%s">view raw</a>.</p>',
            Iczelia::Subpages::fmt_size($size), $raw);
        }
      }
      else {
        my $decoded = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK()) };
        $decoded = $bytes unless defined $decoded;
        my $lang = $type->{lang} // 'plain';
        my $hl   = Iczelia::Highlight::highlight($decoded, $lang);
        $body_html = _with_line_numbers($hl);
      }
    }

    my @out;
    push @out, '<section class="ab-section">';
    push @out, '<h1 class="ab-h1">:: ' . _breadcrumb($row->{slug}, $clean)
      . sprintf(' <span class="git-meta">%s</span> '
        . '<a class="git-rawlink" href="%s">raw</a></h1>',
        Iczelia::Subpages::fmt_size($size), $raw);
    push @out, '<div class="git-blob">' . $body_html . '</div>';
    push @out, '</section>';
    push @out, _tab_prefs($tab, $wrap);

    return _render($ctx,
      "iczelia :: git :: $row->{slug} :: $clean",
      join("\n", @out), $tab, $wrap,
      repo_slug => $row->{slug}, active_tab => 'tree');
  });
}

sub _raw {
  my ($ctx, $req) = @_;
  my $slug  = $req->{caps}{slug};
  my $path  = $req->{caps}{path} // '';
  my $clean = Iczelia::Subpages::sanitize_rel_path($path);
  return Iczelia::HTTP::error(404) unless defined $clean;
  my ($row, $rpath, $why) = _open($ctx, $slug);
  return Iczelia::HTTP::error(404) unless $rpath;
  my ($bytes, $size, $sha) =
    Iczelia::Git::blob($rpath, 'HEAD', $clean, max_bytes => RAW_MAX_BYTES);
  return Iczelia::HTTP::error(404) unless defined $size;
  return {
    status => 413,
    headers => {'Content-Type' => 'text/plain; charset=utf-8'},
    body => "file too large ($size bytes)\n",
  } unless defined $bytes;
  return {
    status => 200,
    headers => {
      'Content-Type'           => Iczelia::Subpages::detect_file_type($clean, $bytes)->{content_type},
      'Cache-Control'          => 'no-store',
      'X-Content-Type-Options' => 'nosniff',
    },
    _no_cache => 1,
    body => $bytes,
  };
}

sub _commit {
  my ($ctx, $req) = @_;
  my $slug = $req->{caps}{slug};
  my $sha  = $req->{caps}{sha};
  return Iczelia::HTTP::error(404)
    unless defined $sha && $sha =~ /^[0-9a-fA-F]{7,64}\z/;
  $sha = lc $sha;
  return _route($ctx, $req, sub {
    my ($tab) = @_;
    my ($row, $rpath, $why) = _open($ctx, $slug);
    return _not_found($ctx, $tab) if $why && $why eq '404';
    if ($why && $why ne 'empty') { return _empty($ctx, $row, $tab, $why) }
    return _empty($ctx, $row, $tab, 'empty') unless $rpath;
    my $c = Iczelia::Git::commit($rpath, $sha);
    return _not_found($ctx, $tab) unless $c;

    my @parents;
    for my $p (@{$c->{parents}}) {
      push @parents, sprintf('<a href="/git/%s/commit/%s">%s</a>',
        escape_url($row->{slug}), $p, substr($p, 0, 10));
    }
    my $pstr = @parents
      ? 'parents: ' . join(' ', @parents)
      : '(root commit)';
    my $diff_html = length $c->{diff}
      ? Iczelia::Highlight::highlight($c->{diff}, 'diff')
      : '<p class="empty">no textual diff.</p>';

    my @out;
    push @out, '<section class="ab-section">';
    push @out, sprintf('<h1 class="ab-h1">:: commit '
      . '<span class="git-sha">%s</span></h1>', $c->{sha});
    push @out, sprintf('<p class="git-meta">%s &lt;%s&gt; &mdash; %s</p>',
      escape_html($c->{author}), _mailto($c->{email}),
      _fmt_git_time($c->{ts}));
    push @out, '<p class="git-meta">' . $pstr . '</p>';
    push @out, '<p><strong>' . escape_html($c->{subject}) . '</strong></p>';
    push @out, '<pre class="git-body">' . escape_html($c->{body}) . '</pre>'
      if length $c->{body};
    push @out, '<div class="git-diff">' . $diff_html . '</div>';
    push @out, '</section>';
    push @out, _tab_prefs($tab);

    my $resp = _render($ctx,
      "iczelia :: git :: $row->{slug} :: $c->{short}",
      join("\n", @out), $tab,
      repo_slug => $row->{slug}, active_tab => 'log');
    return $resp;
  });
}

# --- helpers ----------------------------------------------------------

sub _tab_prefs {
  my ($current, $wrap) = @_;
  $current = DEFAULT_TAB unless defined $current;
  $wrap = DEFAULT_WRAP unless defined $wrap;
  my @parts;
  for my $n (@TAB_SIZES) {
    my $on = $n == $current ? ' class="on"' : '';
    push @parts, qq{<a href="?set-tab=$n"$on>$n</a>};
  }
  my $wrap_off = $wrap ? '' : ' class="on"';
  my $wrap_on  = $wrap ? ' class="on"' : '';
  return '<div class="git-prefs"><span class="tab">tab: '
    . join('', @parts) . '</span>'
    . qq{ <span class="wrap">wrap: <a href="?set-wrap=0"$wrap_off>off</a>}
    . qq{<a href="?set-wrap=1"$wrap_on>on</a></span></div>};
}

sub _fmt_git_time {
  my ($ts) = @_;
  return '-' unless $ts;
  my $stamp = Iczelia::Subpages::fmt_mtime($ts);
  my $color = _age_color($ts);
  return sprintf('<span class="git-age" style="color:%s">%s</span>',
    $color, escape_html($stamp));
}

sub _age_color {
  my ($ts) = @_;
  my $age = time - ($ts || 0);
  $age = 0 if $age < 0;
  my $year = 365 * 24 * 60 * 60;
  my $f = 1 - ($age / $year);
  $f = 0 if $f < 0;
  $f = 1 if $f > 1;
  my @old = (110, 164, 214); # blue: old dates
  my @new = (117, 201, 138); # green: recent dates
  return sprintf('#%02x%02x%02x',
    map { int($old[$_] + (($new[$_] - $old[$_]) * $f)) } 0 .. 2);
}

sub _mailto {
  my ($email) = @_;
  return '' unless defined $email && length $email;
  my $e = escape_html($email);
  return sprintf('<a href="mailto:%s">%s</a>', escape_url($email), $e);
}

sub _ref_table {
  my ($slug, $refs, $kind, %opt) = @_;
  unless ($refs && @$refs) {
    my $plural = $kind eq 'branch' ? 'branches' : "$kind" . 's';
    return '<p class="empty">no ' . escape_html($plural) . '.</p>';
  }
  my $total = scalar @$refs;
  my @show = @$refs;
  if ($opt{limit} && @show > $opt{limit}) {
    splice @show, $opt{limit};
  }
  my @cells;
  for my $r (@show) {
    my $name = $r->{name} // '';
    my $when = $r->{ts} ? ' <span class="git-ref-time">('
      . _fmt_git_time($r->{ts}) . ')</span>' : '';
    push @cells, sprintf(
      '<td><a href="/git/%s/log/?h=%s">%s</a>%s</td>',
      escape_url($slug), escape_url($name), escape_html($name), $when
    );
  }
  my $html = '<table class="git-ref-table"><tbody><tr>'
    . join('', @cells) . '</tr></tbody></table>';
  if ($opt{limit} && $total > $opt{limit} && length($opt{all_href} // '')) {
    my $plural = $kind eq 'branch' ? 'branches' : "$kind" . 's';
    $html .= sprintf(
      '<p class="git-ref-more"><a href="%s">all %s &gt;&gt;</a></p>',
      $opt{all_href}, escape_html($plural)
    );
  }
  return $html;
}

sub _breadcrumb {
  my ($slug, $clean) = @_;
  my @segs = length $clean ? split(m{/}, $clean) : ();
  my @links = (sprintf('<a href="/git/%s/tree/">%s</a>',
    escape_url($slug), escape_html($slug)));
  my $acc = '';
  for my $i (0 .. $#segs - 1) {
    $acc = length $acc ? "$acc/$segs[$i]" : $segs[$i];
    push @links, sprintf('<a href="/git/%s/tree/%s">%s</a>',
      escape_url($slug), _join_url_path('', $acc),
      escape_html($segs[$i]));
  }
  push @links, escape_html($segs[-1]) if @segs;
  return join(' / ', @links);
}

sub _join_url_path {
  my ($dir, $name) = @_;
  my @parts;
  push @parts, split(m{/}, $dir) if defined $dir && length $dir;
  if (defined $name && length $name) {
    push @parts, split(m{/}, $name);
  }
  return join('/', map { escape_url($_) } @parts);
}

sub _readme_html {
  my ($path, $slug) = @_;
  my $entries = Iczelia::Git::tree($path, 'HEAD', '') || [];
  for my $e (@$entries) {
    next if $e->{type} ne 'file';
    next unless Iczelia::Subpages::is_readme_name($e->{name});
    my ($bytes, $size, $sha) = Iczelia::Git::blob($path, 'HEAD',
      $e->{name}, max_bytes => README_MAX_BYTES);
    next unless defined $bytes;
    my $decoded = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK()) };
    my $text    = defined $decoded ? $decoded : $bytes;
    my $name    = escape_html($e->{name});
    my $caption = qq{<div class="git-readme-name">$name</div>};

    if ($e->{name} =~ /\.(?:md|markdown)\z/i) {
      # Strip the admin-only RAWHTML markers so a hostile mirrored
      # README can't punch raw HTML through Markup's trusted
      # passthrough.
      $text =~ s/<!--\s*\/?RAWHTML\s*-->//gi;
      $text = substr($text, 0, README_MAX_BYTES)
        if length($text) > README_MAX_BYTES;
      local $Iczelia::Markup::ALLOW_REMOTE_IMAGES = 1;
      my ($html) = Iczelia::Markup::render($text);
      $html //= '';
      $html =~ s/__MATH(\d+)__/[math]/g;
      $html = _rewrite_readme_img_srcs($html, $slug);
      return qq{<section class="git-readme">$caption$html</section>};
    }
    return qq{<section class="git-readme">$caption}
      . '<pre><code>' . escape_html($text) . '</code></pre></section>';
  }
  return '';
}

# Wrap a highlighted <pre class="hl ..."><code>...</code></pre> in a
# line-numbered table. Each row gets id="Ln" and a clickable anchor
# in the gutter so URLs like /git/repo/blob/foo.c#L42 jump to and
# highlight line 42. Splits the inner <code> HTML span-safely so
# multi-line tokens (C block comments, Python triple-quoted strings)
# keep their colour past the newline.
sub _with_line_numbers {
  my ($pre_html) = @_;
  return $pre_html unless defined $pre_html && length $pre_html;

  # Extract <pre class="hl lang-X"><code>INNER</code></pre>. We pull
  # out the lang-X suffix so the table can wear it for any lang-
  # specific CSS that needs to scope.
  my ($pre_class, $inner) = $pre_html =~
    m{\A<pre\s+class="([^"]+)"><code>(.*)</code></pre>\s*\z}s;
  unless (defined $inner) {
    # Highlighter returned something we don't recognise; bail out.
    return $pre_html;
  }
  # Merge .git-lines + the highlighter's existing class list (hl
  # lang-X) into one valid class attribute. Two class= attrs on the
  # same element is invalid HTML and old browsers do strange things.
  my $cls = "git-lines $pre_class";

  my @lines = _split_html_lines($inner);
  # Trailing newline at EOF -> one empty cell after the last real line.
  pop @lines if @lines && $lines[-1] eq '';

  my @rows;
  my $n = @lines;
  my $width = length(sprintf '%d', $n || 1);
  for my $i (0 .. $#lines) {
    my $no   = $i + 1;
    my $code = $lines[$i];
    # An empty line should still occupy a row; &#x200b; is a zero-
    # width space so the cell has content for old browsers that
    # collapse empty cells.
    $code = '&#x200b;' if !length $code;
    push @rows, sprintf(
      '<tr id="L%d"><td class="ln"><a href="#L%d">%*d</a></td>'
      . '<td class="lc"><pre>%s</pre></td></tr>',
      $no, $no, $width, $no, $code
    );
  }
  return qq{<table class="$cls"><tbody>}
    . join("\n", @rows) . '</tbody></table>';
}

# Span-aware line splitter. Walks the highlighter output character by
# character, keeping a stack of currently-open <span> tags. At each
# '\n' it closes them all (so the line is well-formed HTML), emits
# the line, then reopens them on the next line so the colour
# continues. Assumes the input only ever contains <span class="...">
# / </span> tags and entity references; the highlighter's output
# does exactly that.
sub _split_html_lines {
  my ($html) = @_;
  my @lines;
  my $buf = '';
  my @open;
  my $len = length $html;
  my $i   = 0;
  while ($i < $len) {
    my $ch = substr($html, $i, 1);
    if ($ch eq '<') {
      my $end = index($html, '>', $i);
      last if $end < 0;
      my $tag = substr($html, $i, $end - $i + 1);
      $buf .= $tag;
      if    ($tag =~ m{^<span\b}i) { push @open, $tag }
      elsif ($tag =~ m{^</span\b}i && @open) { pop @open }
      $i = $end + 1;
    }
    elsif ($ch eq "\n") {
      $buf .= '</span>' for reverse @open;
      push @lines, $buf;
      $buf = '';
      $buf .= $_ for @open;
      $i++;
    }
    else {
      # Run of plain chars / entities up to the next < or \n.
      my $next = $i;
      while ($next < $len) {
        my $c = substr($html, $next, 1);
        last if $c eq '<' || $c eq "\n";
        $next++;
      }
      $buf .= substr($html, $i, $next - $i);
      $i = $next;
    }
  }
  push @lines, $buf if length $buf || !@lines;
  return @lines;
}

sub _rewrite_readme_img_srcs {
  my ($html, $slug) = @_;
  return $html unless defined $slug && length $slug;
  $html =~ s{
        (<img\b[^>]*?\bsrc=") ([^"]+) (")
    }{
      my ($lead, $src, $tail) = ($1, $2, $3);
      if ($src =~ m{^(?:/|https?://|data:|mailto:|\#|\?)}i) {
        $lead . $src . $tail;
      } else {
        my $suffix = '';
        $suffix = $1 if $src =~ s/([?#].*)\z//;
        $lead . sprintf('/git/%s/raw/%s',
          escape_url($slug), _join_url_path('', $src)) . $suffix . $tail;
      }
    }gxe;
  return $html;
}

# Per-(repo, head, dir) "last commit per child" cache. Reads from
# git_commit_cache first; on miss runs a single bulk `git log
# --name-only` walk and persists the result. Cache key includes
# head_sha so a mirror pull (which deletes stale-sha rows in
# Iczelia::Git::Mirrors) drops the cache automatically.
sub _last_commits_cached {
  my ($ctx, $row, $path, $head, $dir) = @_;
  $dir //= '';
  my $db = $ctx->db;
  my $cached = $db->all(
    q{SELECT name, commit_sha, commit_subject, commit_at
        FROM git_commit_cache WHERE repo_id=? AND head_sha=? AND dir=?},
    $row->{id}, $head, $dir
  );
  my %out;
  if ($cached && @$cached) {
    for my $c (@$cached) {
      $out{$c->{name}} = {
        sha     => $c->{commit_sha},
        subject => $c->{commit_subject},
        ts      => $c->{commit_at},
      };
    }
    return \%out;
  }
  my $fresh = Iczelia::Git::last_commits_for_dir($path, 'HEAD', $dir,
    limit => 1500) || {};
  if (%$fresh) {
    eval {
      $db->tx(sub {
        my $d = shift;
        for my $name (keys %$fresh) {
          my $r = $fresh->{$name};
          $d->do_(
            q{INSERT OR REPLACE INTO git_commit_cache
                (repo_id, head_sha, dir, name, commit_sha,
                 commit_subject, commit_at)
                VALUES(?,?,?,?,?,?,?)},
            $row->{id}, $head, $dir, $name,
            $r->{sha}, $r->{subject}, $r->{ts}
          );
        }
      });
    };
  }
  return $fresh;
}

sub _not_found {
  my ($ctx, $tab) = @_;
  my $body =
      '<section class="ab-section">'
    . '<h1 class="ab-h1">:: not found</h1>'
    . '<p>no such repository.</p>'
    . '<p><a href="/git/">&lt; back to /git/</a></p>'
    . '</section>'
    . _tab_prefs($tab);
  my $resp = _render($ctx, 'iczelia :: git :: not found', $body, $tab,
    repo_slug => undef);
  $resp->{status} = 404;
  return $resp;
}

sub _empty {
  my ($ctx, $row, $tab, $why) = @_;
  my $note = ($why || '') eq 'nogit'
    ? '<p>git binary not on PATH; the git browser is unavailable.</p>'
    : ($why || '') eq 'empty'
    ? '<p>repository is empty (no on-disk store yet).</p>'
    : '<p>repository unavailable.</p>';
  my $body =
      '<section class="ab-section">'
    . sprintf('<h1 class="ab-h1">:: %s</h1>',
        escape_html(length $row->{title} ? $row->{title} : $row->{slug}))
    . '<h2 class="ab-h2">empty</h2>' . $note
    . '</section>'
    . _tab_prefs($tab);
  return _render($ctx, "iczelia :: git :: $row->{slug}", $body, $tab,
    repo_slug => $row->{slug}, active_tab => 'summary');
}

1;
