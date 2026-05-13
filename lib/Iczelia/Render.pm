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

package Iczelia::Render;
use strict;
use warnings;
use Carp            qw(croak);
use JSON::PP        ();
use Encode          ();
use Iczelia::Util   qw(escape_html escape_attr);
use Iczelia::Time   qw(fmt_date fmt_ago atom_iso clock_string);
use Iczelia::Markup ();
use Iczelia::Minify ();

use constant SETTINGS_CACHE_TTL => 60;

# DB rows -> markdown -> math substitution -> template render,
# caching the final HTML back to the row's rendered_html column.

my $JSON = JSON::PP->new->utf8(0)->canonical(1);

my %KAPPA_LABEL = (
  "\x{03c6}" => 'philosophy',
  "\x{03c0}" => 'science',
  "\x{03bb}" => 'code',
  "\x{03b4}" => 'release',
  "\x{03c9}" => 'opinion',
  "\x{03bc}" => 'meta',
);

sub _kappa_title {
  my ($kappa) = @_;
  return '' unless defined $kappa && length $kappa;
  my @parts;
  for my $g (split /\s+/, $kappa) {
    push @parts, "$g $KAPPA_LABEL{$g}" if $KAPPA_LABEL{$g};
  }
  return join(' / ', @parts);
}

sub new {
  my ($class, %arg) = @_;
  croak "db required"       unless $arg{db};
  croak "template required" unless $arg{template};
  my $self = bless {
    db       => $arg{db},
    template => $arg{template},
    tex      => $arg{tex},        # optional Iczelia::Tex
    cache    => $arg{cache},      # optional Iczelia::Cache
    cfg      => $arg{cfg},
  }, $class;
  return $self;
}

sub render_home {
  my ($self) = @_;

  # Home re-renders per request: it embeds a live GMT clock.
  my $page = $self->{db}->row(q{SELECT * FROM pages WHERE slug='home'});
  return undef unless $page;
  my $data = _decode_data($page->{data});

  my $profile_html = $self->_md($data->{profile} // '', inline => 1);
  my $cur_row      = $self->{db}->row(
    q{SELECT text FROM activity WHERE source='currently'
                 ORDER BY position LIMIT 1}
  );
  my $currently = ($cur_row && defined $cur_row->{text}) ? $cur_row->{text} : '';

  # Three latest updates. mid/extra flags drive the chrome's responsive
  # separators (middle >= 800px, third >= 1024px).
  my $rows = $self->{db}->all(
    q{SELECT date, body FROM updates ORDER BY position DESC, id DESC LIMIT 3});
  my @updates;
  for my $i (0 .. $#$rows) {
    my $r         = $rows->[$i];
    my $body_html = $self->_md($r->{body}, inline => 1);
    my $is_mid    = $i == 1      ? 1 : 0;
    my $is_extra  = $i == 2      ? 1 : 0;
    my $sep_after = $i < $#$rows ? 1 : 0;
    push @updates,
      {
      date_fmt  => fmt_date($r->{date}),
      body_html => $body_html,
      mid       => $is_mid,
      extra     => $is_extra,
      sep_after => $sep_after,
      sep_mid   => ($is_mid   ? 1 : 0),
      sep_extra => ($is_extra ? 1 : 0),
      };
  }

  # Grouped by source; position 0 = most recent.
  my $act = $self->{db}->all(
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

  # GitHub: collapse repeats with an "(xN)" suffix, cap at 3 entries.
  my @gh;
  my %gh_idx;
  for my $a (@{$by_src{github}}) {
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
  $by_src{github} = \@gh;

  # Mastodon / Bluesky: keep only the most recent entry per platform.
  for my $k (qw(mastodon bluesky)) {
    my $first = (@{$by_src{$k}}) ? [$by_src{$k}[0]] : [];
    $by_src{$k} = $first;
    for my $a (@$first) {
      $a->{ago} = $a->{posted_at} ? fmt_ago($a->{posted_at}) : '';
    }
  }

  my $github_compact = @{$by_src{github}} ? [$by_src{github}[0]] : [];

  my $teaser = $self->{db}->row(
    q{SELECT slug, title, date FROM posts
          WHERE kind='blog' AND draft=0
            AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
          ORDER BY date DESC, created_at DESC, id DESC LIMIT 1}
  );
  my $teaser_v;
  if ($teaser) {
    $teaser_v = {
      title    => $teaser->{title},
      date_fmt => fmt_date($teaser->{date}),
      url      => "/blog/$teaser->{slug}/",
    };
  }

  my $vars = $self->base_vars(
    title => $page->{title},
    page  => {is_home => 1},
    meta  => {canonical => '/'},
    data  => {
      profile_html => $profile_html,
      currently    => $currently,
    },
    updates  => \@updates,
    activity => {
      github         => $by_src{github},
      mastodon       => $by_src{mastodon},
      bluesky        => $by_src{bluesky},
      github_compact => $github_compact,
    },
    blog_teaser => $teaser_v,
    clock       => clock_string(),
    home_css    => $self->_home_css,
  );

  return $self->{template}->render('views/home.tpl', $vars);
}

sub _home_css {
  my ($self) = @_;
  return $self->{_home_css} ||= do {
    my $dir = $self->{cfg} && $self->{cfg}{'chrome-dir'};
    my %out;
    if ($dir) {
      my %map = (
        common => 'common.compat.css',
        s600   => 'style.600.compat.css',
        mobile => 'style.mobile.compat.css',
        s800   => 'style.800.compat.css',
        s1024  => 'style.1024.compat.css',
      );
      for my $k (keys %map) {
        my $path = "$dir/$map{$k}";
        open my $fh, '<:encoding(UTF-8)', $path
          or do {$out{$k} = ''; next};
        local $/;
        my $css = <$fh>;
        close $fh;
        $out{$k} = Iczelia::Minify::css($css);
      }
    }
    \%out;
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

  my $data    = _decode_data($page->{data});
  my $tplname = "views/$page->{template}.tpl";

  my $cooked = $self->_cook_page_data($page->{template}, $data);

  my %meta = (og_title => $page->{title});
  if (defined $tag_filter && length $tag_filter) {

    # The ?tag= form duplicates the canonical /<slug>/tag/<tag>/ URL.
    $meta{canonical} = "/$slug/tag/" . _url_seg($tag_filter) . '/';
    $meta{robots}    = 'noindex,follow';
  }
  else {
    $meta{canonical} = "/$slug/";
  }
  for my $f (qw(intro_html body_html)) {
    next unless defined $cooked->{$f} && length $cooked->{$f};
    my $d = _meta_desc($cooked->{$f});
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
  elsif ($page->{template} eq 'guestbook') {
    $vars->{entries} = $self->_load_guestbook_entries;
    $vars->{csrf}    = '';
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

  my $data = _decode_data($row->{data});
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
    my $d = _meta_desc($cooked{$f});
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
  my @tags      = grep {length} split /\s*,\s*/, ($row->{tags} || '');

  my $vars = $self->base_vars(
    title => "iczelia :: " . $row->{title},
    page  => {('is_' . $kind) => 1},
    meta  => {
      canonical      => "/$kind/$slug/",
      og_type        => 'article',
      og_title       => $row->{title},
      description     => _meta_desc($body_html),
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
      kappa_title => _kappa_title($row->{kappa}),
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
  my $data = _decode_data($page->{data});
  return $self->_md($data->{intro} // '', inline => 1);
}

# Index for a kind with no published posts: a real page (current year,
# empty list) rather than 404. Year archives still 404 when empty.
sub _render_empty_kind_index {
  my ($self, $kind, $tpl) = @_;
  my $year = (gmtime)[5] + 1900;
  my $intro_html = $self->_kind_intro_html($kind);
  my $vars = $self->base_vars(
    title       => "iczelia :: $kind",
    title_short => $kind,
    slug        => $kind,
    page        => {"is_$kind" => 1},
    meta        => {
      canonical  => "/$kind/",
      description => (length $intro_html ? _meta_desc($intro_html)
        : "No $kind posts yet."),
    },
    data      => {intro_html => $intro_html},
    posts     => [],
    entries   => [],
    cur_year  => $year,
    years     => [{year => $year, current => 1}],
    prev_year => undef,
    next_year => undef,
  );
  return $self->{template}->render($tpl, $vars);
}

sub render_journal_index {
  my ($self) = @_;
  my $nav = $self->_year_nav_data('journal', undef);
  return $self->_render_empty_kind_index('journal', 'views/journal.tpl')
    unless $nav;
  return $self->render_journal_year($nav->{cur_year}, canonical => '/journal/');
}

sub render_journal_year {
  my ($self, $year, %opt) = @_;
  return undef unless $year && $year =~ /^\d{4}$/;
  my $nav = $self->_year_nav_data('journal', $year);
  return undef unless $nav;
  my $rows = $self->{db}->all(
    q{SELECT id, slug, title, date, body, tags, kappa
            FROM posts
           WHERE kind='journal' AND draft=0
             AND substr(date,1,4) = ?
             AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC, created_at DESC, id DESC},
    sprintf('%04d', $year)
  );
  return undef unless @$rows;

  my @entries;
  for my $r (@$rows) {
    my @tags = grep {length} split /\s*,\s*/, ($r->{tags} || '');
    push @entries,
      {
      slug        => $r->{slug},
      title       => $r->{title},
      date_fmt    => fmt_date($r->{date}),
      body_html   => $self->_md($r->{body}),
      tags        => \@tags,
      kappa       => $r->{kappa} // '',
      kappa_title => _kappa_title($r->{kappa}),
      };
  }
  my $intro_html = $self->_kind_intro_html('journal');
  my $vars       = $self->base_vars(
    title       => "iczelia :: journal :: $year",
    title_short => 'journal',
    slug        => 'journal',
    page        => {is_journal => 1},
    meta        => {
      canonical => ($opt{canonical} // "/journal/year/$year/"),
      description => (length $intro_html ? _meta_desc($intro_html)
        : "Journal entries from $year."),
    },
    data    => {intro_html => $intro_html},
    entries => \@entries,
    %$nav,
  );
  return $self->{template}->render('views/journal.tpl', $vars);
}

sub render_blog_index {
  my ($self) = @_;
  my $nav = $self->_year_nav_data('blog', undef);
  return $self->_render_empty_kind_index('blog', 'views/blog.tpl') unless $nav;
  return $self->render_blog_year($nav->{cur_year}, canonical => '/blog/');
}

sub render_blog_year {
  my ($self, $year, %opt) = @_;
  return undef unless $year && $year =~ /^\d{4}$/;
  my $nav = $self->_year_nav_data('blog', $year);
  return undef unless $nav;
  my $rows = $self->{db}->all(
    q{SELECT slug, title, date, tags, kappa
            FROM posts
           WHERE kind='blog' AND draft=0
             AND substr(date,1,4) = ?
             AND (publish_at IS NULL OR publish_at <= strftime('%s','now'))
        ORDER BY date DESC, created_at DESC, id DESC},
    sprintf('%04d', $year)
  );
  return undef unless @$rows;

  my @posts;
  for my $r (@$rows) {
    my @tags = grep {length} split /\s*,\s*/, ($r->{tags} || '');
    push @posts,
      {
      slug        => $r->{slug},
      title       => $r->{title},
      date_fmt    => fmt_date($r->{date}),
      url         => "/blog/$r->{slug}/",
      tags        => \@tags,
      kappa       => $r->{kappa} // '',
      kappa_title => _kappa_title($r->{kappa}),
      };
  }
  my $intro_html = $self->_kind_intro_html('blog');
  my $vars       = $self->base_vars(
    title       => "iczelia :: blog :: $year",
    title_short => 'blog',
    slug        => 'blog',
    page        => {is_blog => 1},
    meta        => {
      canonical => ($opt{canonical} // "/blog/year/$year/"),
      description => (length $intro_html ? _meta_desc($intro_html)
        : "Blog posts from $year."),
    },
    data  => {intro_html => $intro_html},
    posts => \@posts,
    %$nav,
  );
  return $self->{template}->render('views/blog.tpl', $vars);
}

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
  my $data       = _decode_data($page->{data});
  my $intro_html = $self->_md($data->{intro} // '', inline => 0);
  return $self->{template}->render(
    'views/list.tpl',
    $self->base_vars(
      title => "iczelia :: $kind / #$tag",
      page  => {('is_' . $kind) => 1},
      meta  => {
        canonical   => "/$kind/tag/" . _url_seg($tag) . '/',
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
        ORDER BY date DESC, created_at DESC, id DESC LIMIT 60},
    $kind
  );
  my @match;
  for my $r (@$rows) {
    my @tags = split /\s*,\s*/, ($r->{tags} || '');
    next unless grep {$_ eq $tag} @tags;
    push @match, $r;
    last if @match >= 30;
  }
  return undef unless @match;
  my $self_url  = "$base/$kind/tag/" . _url_seg($tag) . "/feed.xml";
  my $alternate = "$base/$kind/tag/" . _url_seg($tag) . "/";
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
  push @bits, qq{  <link href="} . escape_attr($alternate) . qq{" />\n};
  push @bits,
    qq{  <link rel="self" href="} . escape_attr($self_url) . qq{" />\n};
  push @bits, qq{  <id>} . escape_attr($self_url) . qq{</id>\n};
  push @bits, qq{  <updated>} . atom_iso($latest_ts) . qq{</updated>\n};

  for my $r (@match) {
    my $url       = "$base/$kind/$r->{slug}/";
    my $te        = escape_html($r->{title});
    my $upd       = atom_iso($r->{updated_at} || time);
    my $body_html = $self->_md($r->{body});
    my $body_esc  = escape_html($body_html);
    push @bits, qq{  <entry>\n};
    push @bits, qq{    <title>$te</title>\n};
    push @bits, qq{    <link href="} . escape_attr($url) . qq{" />\n};
    push @bits, qq{    <id>} . escape_attr($url) . qq{</id>\n};
    push @bits, qq{    <updated>$upd</updated>\n};
    push @bits, qq{    <content type="html">$body_esc</content>\n};
    push @bits, qq{  </entry>\n};
  }
  push @bits, qq{</feed>\n};
  return join '', @bits;
}

sub _url_seg {
  my ($s) = @_;
  $s =~ s/([^A-Za-z0-9_.~\-])/sprintf('%%%02X', ord($1))/ge;
  return $s;
}

sub base_vars {
  my ($self, %extra) = @_;
  my $now = time;
  if (!$self->{_settings_cache}
    || $now - ($self->{_settings_at} // 0) >= SETTINGS_CACHE_TTL)
  {
    my $rows = $self->{db}->all('SELECT key, value FROM settings');
    my %s;
    for my $r (@$rows) {
      my ($k, $v) = ($r->{key}, $r->{value});
      my @parts = split /\./, $k, 2;
      if   (@parts == 2) {$s{$parts[0]}{$parts[1]} = $v}
      else               {$s{$k}                   = $v}
    }
    $self->{_settings_cache} = \%s;
    $self->{_settings_at}    = $now;
    delete $self->{_theme_css_cache};
  }

  # Shallow-copy the top level so per-call %extra additions don't
  # leak back into the cache.
  my %s      = %{$self->{_settings_cache}};
  my $author = $s{site}{author} // '';

  # Synthesise "(c) START - YEAR HOLDER" when the operator didn't.
  my $now_year = (gmtime)[5] + 1900;
  my $copy     = $s{site}{copyright};
  unless (defined $copy && length $copy) {
    my $start  = $s{site}{copyright_start}  // 2019;
    my $holder = $s{site}{copyright_holder} // ($author || 'iczelia');
    $copy = "(c) $start - $now_year $holder";
  }

  # short = "(c) <years>", author = holder. Lets the chrome drop
  # the holder at narrow breakpoints.
  my $copy_short  = $copy;
  my $copy_author = $s{site}{copyright_holder} // $author;
  $copy_short =~ s/\s*\(c\)/(c)/;
  if ($copy_short =~ s/^(.*\d{4})\s+(\S.*)$/$1/) {
    $copy_author = $2 unless defined $s{site}{copyright_holder};
  }

  my $email      = $s{site}{email} // '';
  my $email_html = _obfuscate_email($email);

  my $theme_css = $self->{_theme_css_cache} //= _theme_css(\%s);
  my %math      = _math_params(\%s);
  my %figure    = _figure_params(\%s);

  # SEO/social <head> metadata. Callers pass `meta => {...}` to
  # override the website-wide defaults (canonical URL, description,
  # keywords, og:type, article timestamps, robots, ...). Relative
  # paths in canonical/image are resolved against site.base_url.
  my $base_url = $s{site}{base_url} // '';
  $base_url =~ s{/+$}{};
  my %meta = (
    description    => $s{site}{description} // $s{site}{tagline} // '',
    keywords       => $s{site}{keywords}    // '',
    canonical      => '',
    og_type        => 'website',
    og_title       => '',
    published_time => '',
    modified_time  => '',
    robots         => '',
  );
  if (ref $extra{meta} eq 'HASH') {
    my $o = delete $extra{meta};
    %meta = (%meta, %$o);
  }

  # og:image: explicit override, else first body image, else site card,
  # else logo. Made absolute below. (posts use `post`, pages use `data`.)
  unless (length($meta{image} // '')) {
    my $post = ref $extra{post} eq 'HASH' ? $extra{post} : {};
    my $data = ref $extra{data} eq 'HASH' ? $extra{data} : {};
    $meta{image} =
         _first_content_img($post->{body_html})
      || _first_content_img($data->{body_html})
      || _first_content_img($data->{intro_html})
      || $s{site}{og_image}
      || '/assets-1024x768/iczelia-128.png';
  }

  for my $k (qw(canonical image)) {
    next unless defined $meta{$k} && $meta{$k} =~ m{^/};
    $meta{$k} = "$base_url$meta{$k}" if length $base_url;
  }
  $meta{og_url} = $meta{canonical} unless defined $meta{og_url};
  $meta{og_locale} = $s{site}{og_locale} // 'en_US'
    unless defined $meta{og_locale};

  # og:title: an explicit override, else the page <title> with the
  # "<site> :: " prefix dropped so it doesn't echo og:site_name.
  my $site_title = $s{site}{title} // 'iczelia';
  my $og_title   = $meta{og_title};
  $og_title = $extra{title} if !defined $og_title || !length $og_title;
  $og_title = $site_title   if !defined $og_title || !length $og_title;
  $og_title =~ s/^\Q$site_title\E\s*::\s*//;
  $meta{og_title} = length $og_title ? $og_title : $site_title;

  return {
    site => {
      base_url         => $base_url,
      copyright        => $copy,
      copyright_short  => $copy_short,
      copyright_author => $copy_author,
      email            => $email,
      email_html       => $email_html,
      tagline          => $s{site}{tagline} // '',
      author           => $author,
      title            => $s{site}{title} // 'iczelia',
    },
    social => {
      github   => $s{github}   || {},
      mastodon => $s{mastodon} || {},
      bluesky  => $s{bluesky}  || {},
    },
    chrome => {
      theme_css => $theme_css,
      figure    => \%figure,
      math      => \%math,
    },
    meta => \%meta,
    page => {},
    %extra,
  };
}

# Section names that mark where the real prose starts.
my $INTRO_HEADING_RE = qr{
  \A \s* (?: \d+ [.)]? \s+ )?
  (?: intro(?:duction)? | preliminaries | overview | background
    | abstract | motivation | prologue | preface | context | tl;?dr )
  \b
}xi;

# first <p> with non-empty text, or undef
sub _para_with_text {
  my ($html) = @_;
  return undef unless defined $html;
  while ($html =~ m{<p\b[^>]*>(.*?)</p\s*>}gis) {
    my $c = $1;
    (my $bare = $c) =~ s/<[^>]+>//g;
    $bare =~ s/&\#?\w+;//g;
    return $c if $bare =~ /\S/;
  }
  return undef;
}

# <meta description> / og:description: intro-section's first para, else
# first para, else whole body; tags stripped, entities decoded, truncated.
sub _meta_desc {
  my ($html, $n) = @_;
  $n ||= 160;
  return '' unless defined $html && length $html;

  my $from = 0;
  while ($html =~ m{<h[1-6]\b[^>]*>(.*?)</h[1-6]\s*>}gis) {
    (my $ht = $1) =~ s/<[^>]+>//g;
    $ht =~ s/&\#?\w+;/ /g;
    $ht =~ s/^\s+//;
    $ht =~ s/\s+/ /g;
    if ($ht =~ $INTRO_HEADING_RE) {$from = pos($html); last}
  }
  my $t = ($from ? _para_with_text(substr($html, $from)) : undef)
       // _para_with_text($html)
       // $html;

  $t =~ s{<[^>]+>}{ }g;
  $t =~ s/&nbsp;/ /g;
  $t =~ s/&amp;/&/g;
  $t =~ s/&lt;/</g;
  $t =~ s/&gt;/>/g;
  $t =~ s/&quot;/"/g;
  $t =~ s/&#0*39;|&apos;/'/g;
  $t =~ s/&#x?[0-9A-Fa-f]+;/ /g;        # any remaining numeric entity
  $t =~ s/&[A-Za-z][A-Za-z0-9]*;/ /g;   # any remaining named entity
  $t =~ s/\s+/ /g;
  # inline tags became spaces; tidy the gap around punctuation
  $t =~ s/ +([.,;:!?)\]}\xbb\x{2026}"'])/$1/g;
  $t =~ s/([(\[{\xab]) +/$1/g;
  $t =~ s/^\s+//;
  $t =~ s/\s+$//;
  if (length $t > $n) {
    $t = substr($t, 0, $n);
    $t =~ s/\s+\S*$//;
    $t .= '...';
  }
  return $t;
}

# first content <img> src, for og:image; skips rendered-LaTeX PNGs
sub _first_content_img {
  my ($html) = @_;
  return '' unless defined $html && length $html;
  while ($html =~ /<img\b([^>]*)>/gi) {
    my $attrs = $1;
    next if $attrs =~ /\bclass\s*=\s*["'][^"']*\bmath\b/i;
    if ($attrs =~ /\bsrc\s*=\s*["']([^"']+)["']/i) {
      my $src = $1;
      $src =~ s/&amp;/&/g;
      return $src;
    }
  }
  return '';
}

# Decoy spans (.no-spam / .fake, aria-hidden) feed naive scrapers
# garbage; sighted readers see the real address.
sub _obfuscate_email {
  my ($e) = @_;
  return '' unless defined $e && $e =~ /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/;
  my ($user, $domain) = split /\@/, $e, 2;
  my @dom_parts = split /\./, $domain;
  return Iczelia::Util::escape_html($e) if @dom_parts < 2;
  my $tld  = pop @dom_parts;
  my $rest = join('.', @dom_parts);
  my $u    = Iczelia::Util::escape_html($user);
  my $r    = Iczelia::Util::escape_html($rest);
  my $t    = Iczelia::Util::escape_html($tld);
  return
      $u
    . '<span class="np" aria-hidden="true">.no-spam</span>@'
    . $r
    . '<span class="np" aria-hidden="true">.fake</span>.'
    . $t;
}

# Inline theme overrides; emits only declarations that differ from
# the static defaults so an untouched install ships nothing.
my %DEFAULT_HL = (
  bg     => '#060912',
  border => '#2a3548',
  text   => '#b9c8d6',
  com    => '#5a7a98',
  str    => '#d8b97e',
  num    => '#c89dd6',
  kw     => '#6ea4d6',
  typ    => '#b8e0f4',
  cst    => '#c89dd6',
  pre    => '#d8a87c',
  attr   => '#d8a87c',
  lt     => '#b8e0f4',
  mac    => '#d8b97e',
  reg    => '#b8e0f4',
  lbl    => '#ffffff',
  gly    => '#6ea4d6',
  sys    => '#d8a87c',
  op     => '#cfdde9',
  pn     => '#6e8aa8',
  id     => '#b9c8d6',
);

sub _theme_css {
  my ($s) = @_;

  # base_vars splits at the first dot only, so `theme.code.kw`
  # lands in $s->{theme}{'code.kw'}; re-flatten here.
  my %hl;
  if (ref $s->{theme} eq 'HASH') {
    for my $k (keys %{$s->{theme}}) {
      if ($k =~ /^code\.(.+)$/) {$hl{$1} = $s->{theme}{$k}}
    }
  }
  my $hl = \%hl;
  my @rules;
  if ( _diff($hl->{bg}, $DEFAULT_HL{bg})
    || _diff($hl->{border}, $DEFAULT_HL{border})
    || _diff($hl->{text},   $DEFAULT_HL{text}))
  {
    my $bg = _ok_color($hl->{bg})     // $DEFAULT_HL{bg};
    my $bd = _ok_color($hl->{border}) // $DEFAULT_HL{border};
    my $tx = _ok_color($hl->{text})   // $DEFAULT_HL{text};
    push @rules, ".hl{background:$bg;border-color:$bd;color:$tx}";
  }
  for my $t (
    sort grep {$_ ne 'bg' && $_ ne 'border' && $_ ne 'text'}
    keys %DEFAULT_HL
    )
  {
    next unless _diff($hl->{$t}, $DEFAULT_HL{$t});
    my $c = _ok_color($hl->{$t}) or next;
    push @rules, ".hl-${t}\{color:$c\}";
  }
  my $fig = $s->{figure} || {};
  if (defined $fig->{bg} || defined $fig->{border}) {
    my @decls;
    if (my $b = _ok_color($fig->{bg}))     {push @decls, "background:$b"}
    if (my $b = _ok_color($fig->{border})) {push @decls, "border-color:$b"}
    push @rules, ".ab-section figure{" . join(';', @decls) . "}" if @decls;
  }
  return @rules ? join('', @rules) : '';
}

sub _diff {
  my ($a, $b) = @_;
  return 0 unless defined $a && length $a;
  return lc $a ne lc($b // '');
}

sub _ok_color {
  my ($c) = @_;
  return undef unless defined $c && length $c;
  return $c if $c =~ /\A#[0-9A-Fa-f]{3,8}\z/;
  return $c if $c =~ /\A(?:rgba?|hsla?)\([0-9.,\s%\/]+\)\z/i;
  return undef;
}

# Force utf8-flagged before the markdown regexes; otherwise a BLOB
# byte string concatenated with PUA sentinels mojibakes.
sub _utf8 {
  my ($s) = @_;
  return '' unless defined $s;
  return $s if Encode::is_utf8($s);
  my $decoded = eval {Encode::decode('UTF-8', $s, Encode::FB_DEFAULT())};
  return defined $decoded ? $decoded : $s;
}

sub _math_params {
  my ($s) = @_;
  my $m = $s->{math} || {};
  return (
    dpi          => _num($m->{dpi},         120, 60, 240),
    inline_pt    => _num($m->{inline_pt},   10,  6,  18),
    display_pt   => _num($m->{display_pt},  11,  6,  20),
    glow_radius  => _num($m->{glow_radius}, 2,   0,  8),
    glow_opacity => _flt($m->{glow_opacity}, 0.55, 0, 1),
  );
}

sub _figure_params {
  my ($s) = @_;
  my $f = $s->{figure} || {};
  return (
    bg     => _ok_color($f->{bg})     // '',
    border => _ok_color($f->{border}) // '#2a3548',
  );
}

sub _num {
  my ($v, $def, $min, $max) = @_;
  return $def unless defined $v && $v =~ /\A-?\d+\z/;
  return $v < $min ? $min : ($v > $max ? $max : $v + 0);
}

sub _flt {
  my ($v, $def, $min, $max) = @_;
  return $def unless defined $v && $v =~ /\A-?\d+(?:\.\d+)?\z/;
  return $v < $min ? $min : ($v > $max ? $max : $v + 0);
}

sub _cook_page_data {
  my ($self, $template, $data) = @_;
  my %out = %$data;

  # Block-level markdown fields: <name> -> <name>_html. Names must match
  # the kind:"markdown" fields declared in share/templates/pages/*.json.
  for my $f (
    qw(
    intro body
    reach_out employment talks links hardware setup patreon misc qr
    experience education works
    )
    )
  {
    if (defined $data->{$f}) {
      $out{"${f}_html"} = $self->_md($data->{$f});
    }
  }

  # kv-table fields whose values/labels carry inline markdown.
  if (ref $data->{vitals} eq 'ARRAY') {
    $out{vitals} = [
      map {
        {%$_, value_html => $self->_md($_->{value}, inline => 1)}
      } @{$data->{vitals}}
    ];
  }
  if (ref $data->{elsewhere} eq 'ARRAY') {
    $out{elsewhere} = [
      map {
        {%$_, label_html => $self->_md($_->{label}, inline => 1)}
      } @{$data->{elsewhere}}
    ];
  }
  return \%out;
}

sub _md {
  my ($self, $src, %opt) = @_;
  return '' unless defined $src && length $src;
  $src = _utf8($src);
  if ($opt{inline}) {
    my $html = Iczelia::Markup::render_inline($src);
    return $self->substitute_math($html, []);
  }
  my ($html, $math) = Iczelia::Markup::render($src);
  return $self->substitute_math($html, $math);
}

# Replace __MATH<n>__ placeholders with rendered <img>s when Tex is wired.
sub substitute_math {
  my ($self, $html, $math) = @_;

  # Always strip placeholders even when Tex isn't wired, so end users
  # never see literal __MATH<n>__ tokens leak into the page.
  if (!$self->{tex}) {
    $html =~ s{__MATH\d+__}{}g;
    return $html;
  }
  $html =~ s{__MATH(\d+)__}{
        my $entry = $math->[$1];
        $entry ? $self->{tex}->render(@$entry) : '';
    }ge;
  return $html;
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

sub invalidate_page {
  my ($self, $slug) = @_;
  $self->{db}->do_(q{UPDATE pages SET rendered_html=NULL WHERE slug=?}, $slug);
  $self->_bust_for_page($slug);
}

sub invalidate_post {
  my ($self, $kind, $slug) = @_;
  $self->{db}
    ->do_(q{UPDATE posts SET rendered_html=NULL WHERE kind=? AND slug=?},
    $kind, $slug);
  return unless $self->{cache};
  $self->{cache}->bust_many(
    "/$kind/$slug/", "/$kind/",    "/$kind/tags/", '/',
    '/feed.xml',     '/index.xml', '/sitemap.xml',
  );
  $self->{cache}->bust_prefix("/$kind/tag/");
}

sub invalidate_home {$_[0]->invalidate_page('home')}

# Wholesale wipe; used after settings changes and as a manual reset.
sub invalidate_all {
  my ($self) = @_;
  return unless $self->{cache};
  $self->{cache}->bust_all;
}

# URLs that go stale when a given CMS page changes.
sub _bust_for_page {
  my ($self, $slug) = @_;
  return unless $self->{cache};
  my @urls;
  if ($slug eq 'home') {
    @urls = ('/', '/feed.xml', '/index.xml', '/sitemap.xml');
  }
  elsif ($slug eq 'blog' || $slug eq 'journal') {
    @urls = (
      "/$slug/",    "/$slug/tags/", '/', '/feed.xml',
      '/index.xml', '/sitemap.xml'
    );
    $self->{cache}->bust_prefix("/$slug/tag/");
  }
  elsif ($slug eq 'webring'
    || $slug eq 'updates'
    || $slug eq 'guestbook'
    || $slug eq 'about'
    || $slug eq 'cv')
  {
    @urls = ("/$slug/", '/', '/sitemap.xml');
  }
  else {
    @urls = ("/$slug/", '/sitemap.xml');
  }
  $self->{cache}->bust_many(@urls);
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
    my @tags = grep {length} split /\s*,\s*/, ($r->{tags} || '');
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

sub _load_guestbook_entries {
  my ($self) = @_;
  my $rows = $self->{db}->all(
    q{SELECT id, posted_at, nickname, body_html, admin_replied_at, admin_reply_html
          FROM guestbook_entries
          WHERE approved_at IS NOT NULL AND rejected_at IS NULL
          ORDER BY posted_at DESC LIMIT 200}
  );
  my @out;
  for my $r (@$rows) {
    my @t = localtime $r->{posted_at};
    push @out, {
      id        => $r->{id},
      nickname  => $r->{nickname},
      date_fmt  => sprintf('%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3]),
      body_html => $r->{body_html} // '',
      reply     => $r->{admin_reply_html}
      ? {
        date_fmt => $r->{admin_replied_at}
        ? do {
          my @rt = localtime $r->{admin_replied_at};
          sprintf('%04d-%02d-%02d', $rt[5] + 1900, $rt[4] + 1, $rt[3]);
          }
        : '',
        body_html => $r->{admin_reply_html},
        }
      : undef,
    };
  }
  return \@out;
}

sub _decode_data {
  my $s = shift;
  return {} unless defined $s && length $s;
  my $r = eval {$JSON->decode($s)};
  return ref($r) eq 'HASH' ? $r : {};
}

1;
