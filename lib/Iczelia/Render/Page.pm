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

package Iczelia::Render::Page;
use strict;
use warnings;
use Iczelia::Util qw(escape_html escape_url split_tags decode_json_hash);
use Iczelia::Time qw(fmt_date fmt_ago atom_iso clock_string);

use constant TAG_FEED_SCAN_LIMIT => 60;

# Iczelia::Render mixin: page-rendering methods. Pulled into the leaf
# Iczelia::Render via @ISA. $self is an Iczelia::Render instance so
# `$self->_md`, `$self->base_vars`, `$self->_kappa_title` resolve
# through the inheritance chain to the relevant sibling mixin.
# Methods provided here:
#   render_home, render_page, render_post, render_dynamic,
#   render_kind_index, render_kind_year, render_blog_index,
#   render_blog_year, render_journal_index, render_journal_year,
#   render_not_found, render_updates_full, render_tag_page,
#   render_tag_feed; private _year_nav_data, _kind_intro_html,
#   _row_to_entry, _cached_page, _cache_page, _post_list,
#   _home_load_page_data, _home_load_updates, _home_load_activity,
#   _home_collapse_github, _home_load_blog_teaser.

sub render_home {
  my ($self) = @_;

  # Home re-renders per request: it embeds a live GMT clock.
  my ($page, $profile_html, $currently) = $self->_home_load_page_data;
  return undef unless $page;
  my $by_src = $self->_home_load_activity;
  $self->_home_collapse_github($by_src);
  my $github_compact = @{$by_src->{github}} ? [$by_src->{github}[0]] : [];

  my $vars = $self->base_vars(
    title => $page->{title},
    page  => {is_home => 1},
    meta  => {canonical => '/'},
    data  => {
      profile_html => $profile_html,
      currently    => $currently,
    },
    updates  => $self->_home_load_updates,
    activity => {
      github         => $by_src->{github},
      mastodon       => $by_src->{mastodon},
      bluesky        => $by_src->{bluesky},
      github_compact => $github_compact,
    },
    blog_teaser => $self->_home_load_blog_teaser,
    clock       => clock_string(),
    home_css    => $self->_home_css,
  );
  return $self->{template}->render('views/home.tpl', $vars);
}

sub _home_load_page_data {
  my ($self) = @_;
  my $page = $self->{db}->row(q{SELECT * FROM pages WHERE slug='home'});
  return (undef, '', '') unless $page;
  my $data         = decode_json_hash($page->{data});
  my $profile_html = $self->_md($data->{profile} // '', inline => 1);
  my $cur_row      = $self->{db}->row(
    q{SELECT text FROM activity WHERE source='currently'
                 ORDER BY position LIMIT 1}
  );
  my $currently =
    ($cur_row && defined $cur_row->{text}) ? $cur_row->{text} : '';
  return ($page, $profile_html, $currently);
}

# Three latest updates. mid/extra flags drive the chrome's responsive
# separators (middle >= 800px, third >= 1024px).
sub _home_load_updates {
  my ($self) = @_;
  my $rows = $self->{db}->all(
    q{SELECT date, body FROM updates ORDER BY position DESC, id DESC LIMIT 3});
  my @updates;
  for my $i (0 .. $#$rows) {
    my $r        = $rows->[$i];
    my $is_mid   = $i == 1 ? 1 : 0;
    my $is_extra = $i == 2 ? 1 : 0;
    push @updates,
      {
      date_fmt  => fmt_date($r->{date}),
      body_html => $self->_md($r->{body}, inline => 1),
      mid       => $is_mid,
      extra     => $is_extra,
      sep_after => $i < $#$rows ? 1 : 0,
      sep_mid   => $is_mid,
      sep_extra => $is_extra,
      };
  }
  return \@updates;
}

# Activity rows grouped by source; position 0 = most recent. Mastodon /
# Bluesky get trimmed to the latest entry only and annotated with ago.
sub _home_load_activity {
  my ($self) = @_;
  my $act    = $self->{db}->all(
    q{SELECT source, text, url, posted_at FROM activity
          ORDER BY source, position}
  );
  my %by_src;
  for my $a (@$act) {
    push @{$by_src{$a->{source}}},
      {
      text      => $a->{text},
      url       => $a->{url},
      posted_at => $a->{posted_at},
      };
  }
  for my $k (qw(github mastodon bluesky)) {$by_src{$k} ||= []}
  for my $k (qw(mastodon bluesky)) {
    my $first = @{$by_src{$k}} ? [$by_src{$k}[0]] : [];
    $by_src{$k} = $first;
    for my $a (@$first) {
      $a->{ago} = $a->{posted_at} ? fmt_ago($a->{posted_at}) : '';
    }
  }
  return \%by_src;
}

# GitHub: collapse repeats with an "(xN)" suffix, cap at 3 entries.
# Mutates $by_src->{github} in place.
sub _home_collapse_github {
  my ($self, $by_src) = @_;
  my @gh;
  my %gh_idx;
  for my $a (@{$by_src->{github}}) {
    if (defined $gh_idx{$a->{text}}) {
      $gh[$gh_idx{$a->{text}}]{count}++;
    }
    else {
      last if @gh >= 3;
      $gh_idx{$a->{text}} = scalar @gh;
      push @gh, {%$a, count => 1};
    }
  }
  for my $g (@gh) {
    $g->{ago} = $g->{posted_at} ? fmt_ago($g->{posted_at}) : '';

    # Split "<verb> <user>/<repo>" so the chrome can drop user/.
    if ($g->{text} =~ m{^(.*?)([\w][\w.-]*)/([\w][\w.-]*)\s*$}) {
      $g->{prefix} = $1;
      $g->{user}   = $2 . '/';
      $g->{repo}   = $3;
    }
    else {
      $g->{prefix} = $g->{text};
      $g->{user}   = '';
      $g->{repo}   = '';
    }
    $g->{suffix} = $g->{count} > 1 ? " (\x{00d7}$g->{count})" : '';
  }
  $by_src->{github} = \@gh;
}

sub _home_load_blog_teaser {
  my ($self) = @_;
  my $row = $self->{db}->row(
    q{SELECT slug, title, date FROM posts
          WHERE kind='blog' AND draft=0
            AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
          ORDER BY date DESC, created_at DESC, id DESC LIMIT 1}
  );
  return undef unless $row;
  return {
    title    => $row->{title},
    date_fmt => fmt_date($row->{date}),
    url      => "/blog/$row->{slug}/",
  };
}

sub render_page {
  my ($self, $slug, %opt) = @_;
  my $tag_filter = $opt{tag};

  # Cache only the unfiltered view. Tag-filtered list pages re-render.
  if (!defined $tag_filter) {
    my $cached = $self->_cached_page($slug);
    return $cached if defined $cached;
  }

  my $page = $self->{db}->row('SELECT * FROM pages WHERE slug=?', $slug);
  return undef unless $page;

  my $data    = decode_json_hash($page->{data});
  my $tplname = "views/$page->{template}.tpl";

  my $cooked = $self->_cook_page_data($page->{template}, $data);

  my %meta = (og_title => $page->{title});
  if (defined $tag_filter && length $tag_filter) {

    # The ?tag= form duplicates the canonical /<slug>/tag/<tag>/ URL.
    $meta{canonical} = "/$slug/tag/" . escape_url($tag_filter) . '/';
    $meta{robots}    = 'noindex,follow';
  }
  else {
    $meta{canonical} = "/$slug/";
  }
  for my $f (qw(intro_html body_html)) {
    next unless defined $cooked->{$f} && length $cooked->{$f};
    my $d = Iczelia::Render::Markup::_meta_desc($cooked->{$f});
    if (length $d) {$meta{description} = $d; last}
  }

  my $vars = $self->base_vars(
    title       => $page->{title},
    title_short => $slug,
    slug        => $slug,
    page        => {"is_$slug" => 1},
    meta        => \%meta,
    data        => $cooked,
    tag_filter  => $tag_filter,
  );

  if ($page->{template} eq 'webring') {
    my $rows = $self->{db}->all(
      q{SELECT section, name, url, image_url
              FROM webring_members ORDER BY position}
    );
    for my $r (@$rows) {
      $r->{domain} =
        ($r->{url} && $r->{url} =~ m{^https?://([^/]+)}i) ? $1 : '';
      $r->{section} ||= 'others';
    }

    # Preserve first-occurrence order: admin ordering survives.
    my (@order, %by);
    for my $r (@$rows) {
      push @order,                $r->{section} unless $by{$r->{section}};
      push @{$by{$r->{section}}}, $r;
    }
    my %label = (own => 'my own', others => 'others', more => 'more');
    $vars->{ring_sections} = [
      map {
        my $sec = $_;
        {
          name    => $sec,
          label   => $label{$sec} // $sec,
          members => $by{$sec},
          is_more => ($sec eq 'more' ? 1 : 0),
        }
      } @order
    ];
  }
  elsif ($page->{template} eq 'list' && $slug eq 'blog') {
    $vars->{posts} = $self->_post_list('blog', tag => $tag_filter);
  }
  elsif ($page->{template} eq 'list' && $slug eq 'journal') {
    $vars->{posts} = $self->_post_list('journal', tag => $tag_filter);
  }

  my $html = $self->{template}->render($tplname, $vars);
  $self->_cache_page($slug, $html) unless defined $tag_filter;
  return $html;
}

sub render_dynamic {
  my ($self, $route) = @_;
  my $row =
    $self->{db}->row(q{SELECT * FROM dynamic_pages WHERE route=?}, $route);
  return undef unless $row;
  return $row->{rendered_html}
    if defined $row->{rendered_html} && length $row->{rendered_html};

  # Validator-rejected template names 404 instead of path-traversing.
  my $tpl = $row->{template} // '';
  return undef unless $tpl =~ /^[a-z][a-z0-9_-]{0,40}$/;

  my $data = decode_json_hash($row->{data});
  my %cooked;
  for my $k (keys %$data) {
    if ($k eq 'body' || $k eq 'intro') {
      $cooked{"${k}_html"} =
        $self->_md($data->{$k} // '', inline => ($k eq 'intro' ? 1 : 0));
    }
    else {
      $cooked{$k} = $data->{$k};
    }
  }
  my %meta = (canonical => $route, og_title => $row->{title});
  for my $f (qw(body_html intro_html)) {
    next unless defined $cooked{$f} && length $cooked{$f};
    my $d = Iczelia::Render::Markup::_meta_desc($cooked{$f});
    if (length $d) {$meta{description} = $d; last}
  }
  my $html = eval {
    $self->{template}->render(
      "views/$tpl.tpl",
      $self->base_vars(
        title       => $row->{title},
        title_short => $row->{title},
        route       => $route,
        meta        => \%meta,
        data        => \%cooked,
        page        => {is_dynamic => 1},
      )
    );
  };
  if ($@ || !defined $html) {
    warn "render_dynamic($route): $@" if $@;
    return undef;
  }
  $self->{db}->do_(
    q{UPDATE dynamic_pages SET rendered_html=?,
                 rendered_at=strftime('%s','now') WHERE id=?},
    $html, $row->{id}
  );
  return $html;
}

sub render_post {
  my ($self, $kind, $slug) = @_;
  my $row = $self->{db}->row(
    q{SELECT * FROM posts WHERE kind=? AND slug=? AND draft=0
              AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))},
    $kind, $slug
  );
  return undef unless $row;

  if (defined $row->{rendered_html} && length $row->{rendered_html}) {
    return $row->{rendered_html};
  }

  my $body_html = $self->_md($row->{body});
  my @tags      = split_tags($row->{tags});

  my $vars = $self->base_vars(
    title => "iczelia :: " . $row->{title},
    page  => {('is_' . $kind) => 1},
    meta  => {
      canonical      => "/$kind/$slug/",
      og_type        => 'article',
      og_title       => $row->{title},
      description     => Iczelia::Render::Markup::_meta_desc($body_html),
      keywords       => join(', ', @tags),
      published_time => ($row->{date} // ''),
      modified_time  => ($row->{updated_at} ? atom_iso($row->{updated_at}) : ''),
    },
    post => {
      title       => $row->{title},
      date_fmt    => fmt_date($row->{date}),
      tags        => \@tags,
      body_html   => $body_html,
      kind        => $kind,
      slug        => $slug,
      word_count  => $row->{word_count} // 0,
      kappa       => $row->{kappa}      // '',
      kappa_title => Iczelia::Render::_kappa_title($row->{kappa}),
    },
  );

  my $html = $self->{template}->render('views/post.tpl', $vars);
  $self->{db}->do_(
    q{UPDATE posts SET rendered_html=?, rendered_at=strftime('%s','now') WHERE id=?},
    $html, $row->{id}
  );
  return $html;
}

# Latest year with published posts for $kind, plus the descending year
# list and the $year's prev/next neighbours. undef when none.
sub _year_nav_data {
  my ($self, $kind, $year) = @_;
  my $year_strs = $self->{db}->col(
    q{SELECT DISTINCT substr(date,1,4) AS y
            FROM posts
           WHERE kind=? AND draft=0
             AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY y DESC}, $kind
  );
  return undef unless @$year_strs;
  $year //= $year_strs->[0];
  my ($prev, $next);
  my $cur_idx;
  for (my $i = 0; $i < @$year_strs; $i++) {
    if ($year_strs->[$i] + 0 == $year + 0) {
      $cur_idx = $i;
      $next    = $year_strs->[$i - 1] if $i > 0;
      $prev    = $year_strs->[$i + 1] if $i + 1 < @$year_strs;
      last;
    }
  }
  return undef unless defined $cur_idx;
  my @years_meta = map +{
    year    => $_,
    current => ($_ + 0 == $year + 0 ? 1 : 0),
  }, @$year_strs;
  return {
    cur_year  => $year + 0,
    years     => \@years_meta,
    prev_year => $prev,
    next_year => $next,
  };
}

sub _kind_intro_html {
  my ($self, $slug) = @_;
  my $page = $self->{db}->row('SELECT data FROM pages WHERE slug=?', $slug);
  return '' unless $page;
  my $data = decode_json_hash($page->{data});
  return $self->_md($data->{intro} // '', inline => 1);
}

# `entries` for journal (full bodies inline), `posts` for blog (link list).
my %KIND_VIEW = (
  blog => {
    list_key   => 'posts',
    columns    => 'slug, title, date, tags, kappa',
    desc_empty => 'No blog posts yet.',
    year_desc  => sub {"Blog posts from $_[0]."},
  },
  journal => {
    list_key   => 'entries',
    columns    => 'id, slug, title, date, body, tags, kappa',
    desc_empty => 'No journal entries yet.',
    year_desc  => sub {"Journal entries from $_[0]."},
  },
);

sub _row_to_entry {
  my ($self, $kind, $r) = @_;
  my $e = {
    slug        => $r->{slug},
    title       => $r->{title},
    date_fmt    => fmt_date($r->{date}),
    tags        => [split_tags($r->{tags})],
    kappa       => $r->{kappa} // '',
    kappa_title => Iczelia::Render::_kappa_title($r->{kappa}),
  };
  if   ($kind eq 'journal') {$e->{body_html} = $self->_md($r->{body})}
  else                      {$e->{url}       = "/$kind/$r->{slug}/"}
  return $e;
}

sub render_kind_index {
  my ($self, $kind) = @_;
  my $cfg = $KIND_VIEW{$kind} or return undef;
  my $nav = $self->_year_nav_data($kind, undef);
  if (!$nav) {
    my $year       = (gmtime)[5] + 1900;
    my $intro_html = $self->_kind_intro_html($kind);
    my $vars       = $self->base_vars(
      title       => "iczelia :: $kind",
      title_short => $kind,
      slug        => $kind,
      page        => {"is_$kind" => 1},
      meta        => {
        canonical => "/$kind/",
        description => (length $intro_html ? Iczelia::Render::Markup::_meta_desc($intro_html)
          : $cfg->{desc_empty}),
      },
      data            => {intro_html => $intro_html},
      posts           => [],
      entries         => [],
      cur_year        => $year,
      years           => [{year => $year, current => 1}],
      prev_year       => undef,
      next_year       => undef,
    );
    return $self->{template}->render("views/$kind.tpl", $vars);
  }
  return $self->render_kind_year($kind, $nav->{cur_year}, canonical => "/$kind/");
}

sub render_kind_year {
  my ($self, $kind, $year, %opt) = @_;
  my $cfg = $KIND_VIEW{$kind} or return undef;
  return undef unless $year && $year =~ /^\d{4}$/;
  my $nav = $self->_year_nav_data($kind, $year);
  return undef unless $nav;
  my $rows = $self->{db}->all(
    qq{SELECT $cfg->{columns}
            FROM posts
           WHERE kind=? AND draft=0
             AND substr(date,1,4) = ?
             AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC, created_at DESC, id DESC},
    $kind, sprintf('%04d', $year)
  );
  return undef unless @$rows;

  my @items      = map {$self->_row_to_entry($kind, $_)} @$rows;
  my $intro_html = $self->_kind_intro_html($kind);
  my $vars       = $self->base_vars(
    title       => "iczelia :: $kind :: $year",
    title_short => $kind,
    slug        => $kind,
    page        => {"is_$kind" => 1},
    meta        => {
      canonical => ($opt{canonical} // "/$kind/year/$year/"),
      description => (length $intro_html ? Iczelia::Render::Markup::_meta_desc($intro_html)
        : $cfg->{year_desc}->($year)),
    },
    data              => {intro_html => $intro_html},
    $cfg->{list_key}  => \@items,
    %$nav,
  );
  return $self->{template}->render("views/$kind.tpl", $vars);
}

sub render_blog_index    {$_[0]->render_kind_index('blog')}
sub render_journal_index {$_[0]->render_kind_index('journal')}
sub render_blog_year     {my $s = shift; $s->render_kind_year('blog', @_)}
sub render_journal_year  {my $s = shift; $s->render_kind_year('journal', @_)}

# Themed 404 page for browser navigations.
sub render_not_found {
  my ($self, $req) = @_;
  my $path = $req && $req->{path};
  $path = substr($path, 0, 200) if defined $path && length $path > 200;
  my $vars = $self->base_vars(
    title          => 'iczelia :: 404',
    title_short    => '404',
    slug           => '404',
    page           => {is_404 => 1},
    meta           => {robots => 'noindex,nofollow', description => 'Page not found.'},
    requested_path => $path,
  );
  return $self->{template}->render('views/404.tpl', $vars);
}

sub render_updates_full {
  my ($self) = @_;
  my $rows =
    $self->{db}->all(
    q{SELECT date, body FROM updates ORDER BY date DESC, position DESC, id DESC}
    );
  my @items;
  for my $r (@$rows) {
    my $body_html = $self->_md($r->{body}, inline => 1);
    push @items, {date_fmt => fmt_date($r->{date}), body_html => $body_html};
  }
  my $vars = $self->base_vars(
    title => 'iczelia :: updates',
    page  => {is_updates => 1},
    meta  => {canonical => '/updates/', description => 'Site changelog and recent updates.'},
    items => \@items,
  );
  return $self->{template}->render('views/updates.tpl', $vars);
}

# /<kind>/tag/<tag>/ - cacheable canonical URL. Undef if no posts match.
sub render_tag_page {
  my ($self, $kind, $tag) = @_;
  return undef unless $kind eq 'blog' || $kind eq 'journal';
  my $page = $self->{db}->row('SELECT * FROM pages WHERE slug=?', $kind);
  return undef unless $page;
  my $data       = decode_json_hash($page->{data});
  my $intro_html = $self->_md($data->{intro} // '', inline => 0);
  return $self->{template}->render(
    'views/list.tpl',
    $self->base_vars(
      title => "iczelia :: $kind / #$tag",
      page  => {('is_' . $kind) => 1},
      meta  => {
        canonical   => "/$kind/tag/" . escape_url($tag) . '/',
        description  => "Posts in $kind tagged '$tag'.",
      },
      data       => {intro_html => $intro_html},
      posts      => $self->_post_list($kind, tag => $tag),
      tag_filter => $tag,
      tag_kind   => $kind,
      slug       => $kind,
    )
  );
}

# Atom 1.0 feed for one tag. Pulls `tags` directly to avoid an N+1.
sub render_tag_feed {
  my ($self, $kind, $tag) = @_;
  return undef unless $kind eq 'blog' || $kind eq 'journal';
  my $base =
    $self->{db}->one(q{SELECT value FROM settings WHERE key='site.base_url'})
    // '';
  $base =~ s{/+$}{};
  my $rows = $self->{db}->all(
    q{SELECT slug, title, date, body, tags, updated_at
            FROM posts
           WHERE kind=? AND draft=0
             AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC, created_at DESC, id DESC LIMIT } . TAG_FEED_SCAN_LIMIT,
    $kind
  );
  my @match;
  for my $r (@$rows) {
    my @tags = split_tags($r->{tags});
    next unless grep {$_ eq $tag} @tags;
    push @match, $r;
    last if @match >= 30;
  }
  return undef unless @match;
  my $self_url  = "$base/$kind/tag/" . escape_url($tag) . "/feed.xml";
  my $alternate = "$base/$kind/tag/" . escape_url($tag) . "/";
  my $latest_ts = 0;
  for my $r (@match) {
    $latest_ts = $r->{updated_at} if $r->{updated_at} > $latest_ts;
  }
  $latest_ts ||= time;
  my @bits;
  push @bits, qq{<?xml version="1.0" encoding="utf-8"?>\n};
  push @bits, qq{<feed xmlns="http://www.w3.org/2005/Atom">\n};
  my $title = "iczelia :: $kind / #$tag";
  my $tt    = escape_html($title);
  push @bits, qq{  <title>$tt</title>\n};
  push @bits, qq{  <link href="} . escape_html($alternate) . qq{" />\n};
  push @bits,
    qq{  <link rel="self" href="} . escape_html($self_url) . qq{" />\n};
  push @bits, qq{  <id>} . escape_html($self_url) . qq{</id>\n};
  push @bits, qq{  <updated>} . atom_iso($latest_ts) . qq{</updated>\n};

  for my $r (@match) {
    my $url       = "$base/$kind/$r->{slug}/";
    my $te        = escape_html($r->{title});
    my $upd       = atom_iso($r->{updated_at} || time);
    my $body_html = $self->_md($r->{body});
    my $body_esc  = escape_html($body_html);
    push @bits, qq{  <entry>\n};
    push @bits, qq{    <title>$te</title>\n};
    push @bits, qq{    <link href="} . escape_html($url) . qq{" />\n};
    push @bits, qq{    <id>} . escape_html($url) . qq{</id>\n};
    push @bits, qq{    <updated>$upd</updated>\n};
    push @bits, qq{    <content type="html">$body_esc</content>\n};
    push @bits, qq{  </entry>\n};
  }
  push @bits, qq{</feed>\n};
  return join '', @bits;
}

sub _cached_page {
  my ($self, $slug) = @_;
  my $row =
    $self->{db}->row('SELECT rendered_html FROM pages WHERE slug=?', $slug);
  return undef unless $row;
  return $row->{rendered_html};
}

sub _cache_page {
  my ($self, $slug, $html) = @_;
  $self->{db}->do_(
    q{UPDATE pages SET rendered_html=?, rendered_at=strftime('%s','now') WHERE slug=?},
    $html, $slug
  );
}

sub _post_list {
  my ($self, $kind, %opt) = @_;
  my $rows = $self->{db}->all(
    q{SELECT slug, title, date, tags FROM posts
          WHERE kind=? AND draft=0
            AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
          ORDER BY date DESC, created_at DESC, id DESC},
    $kind
  );
  my $tag_filter = $opt{tag};
  my @out;
  for my $r (@$rows) {
    my @tags = split_tags($r->{tags});
    if (defined $tag_filter && length $tag_filter) {
      next unless grep {$_ eq $tag_filter} @tags;
    }
    push @out,
      {
      slug     => $r->{slug},
      title    => $r->{title},
      date_fmt => fmt_date($r->{date}),
      date     => $r->{date},
      tags     => \@tags,
      url      => "/$kind/$r->{slug}/",
      };
  }
  return \@out;
}

1;
