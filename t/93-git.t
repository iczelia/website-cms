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

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";
use IO::Compress::Zip qw(zip $ZipError);

use Iczelia::DB;
use Iczelia::Migrate;
use Iczelia::Subpages;
use Iczelia::SafeMarkup;
use Iczelia::Highlight;
use Iczelia::Theme;
use Iczelia::PublicListing;
use Iczelia::Git;
use Iczelia::Git::Mirrors;
use Iczelia::Handlers::Git;
use Iczelia::Handlers::Admin::Git;
use Iczelia::CachePolicy qw(bypass_for_request);

# -- 1. Hand-rollable bits that don't need Git::Raw -------------------------

is(Iczelia::Subpages::valid_slug('git'), 0,
  "slug 'git' is reserved (would shadow /git/)");
is(Iczelia::Subpages::valid_slug('mygit'), 1,
  'prefix match is fine; only exact reserved word is blocked');

ok(Iczelia::Git::valid_mirror_url('https://github.com/foo/bar.git'),
  'https mirror url accepted');
ok(Iczelia::Git::valid_mirror_url('http://example.org/repo'),
  'http mirror url accepted');
ok(!Iczelia::Git::valid_mirror_url('file:///etc/passwd'),
  'file:// rejected');
ok(!Iczelia::Git::valid_mirror_url('ssh://git@host/repo.git'),
  'ssh:// rejected');
ok(!Iczelia::Git::valid_mirror_url('git://github.com/foo/bar.git'),
  'git:// rejected');
ok(!Iczelia::Git::valid_mirror_url(''),         'empty url rejected');
ok(!Iczelia::Git::valid_mirror_url(undef),      'undef url rejected');
ok(!Iczelia::Git::valid_mirror_url("https://x\nLocation: y"),
  'newline in url rejected (header injection guard)');

is(Iczelia::Highlight::lang_for_filename('foo.py'), 'python', 'python ext');
is(Iczelia::Highlight::lang_for_filename('src/foo.c'), 'c', 'nested c ext');
is(Iczelia::Highlight::lang_for_filename('Makefile'), 'make', 'Makefile name');
is(Iczelia::Highlight::lang_for_filename('Dockerfile'), 'dockerfile',
  'Dockerfile name');
is(Iczelia::Highlight::lang_for_filename('README.md'), 'markdown',
  'README.md -> markdown');
is(Iczelia::Highlight::lang_for_filename('Proof.lean'), 'lean4',
  'Lean extension -> lean4');
is(Iczelia::Highlight::lang_for_filename('weird.xyzzy'), undef,
  'unknown extension -> undef (caller falls back to plain)');
is(Iczelia::Highlight::lang_for_filename(''), undef, 'empty name -> undef');
is(Iczelia::Highlight::lang_for_file('script',
    "#!/usr/bin/env python3\nprint(1)\n"),
  'python', 'shebang detection follows Linguist-style strategy');
is(Iczelia::Highlight::lang_for_file('ambiguous.txt',
    "# -*- mode: ruby -*-\nputs 1\n"),
  'ruby', 'Emacs modeline wins before extension');
is(Iczelia::Highlight::lang_for_file('ambiguous.txt',
    "# vim: ft=lua\nprint('x')\n"),
  'lua', 'Vim modeline detected');
is(Iczelia::Highlight::lang_for_file('unknown',
    "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n"),
  'diff', 'content heuristic detects extensionless diff');

# SafeMarkup max=>N raises the input cap.
{
  my $big = '# h' x 20000;   # ~80 KB
  my ($default_html) = Iczelia::SafeMarkup::render($big);
  ok(length($default_html) > 0 && length($default_html) < 50_000,
    'default render caps input near 8 KB (output bounded)');
  my ($raised_html) = Iczelia::SafeMarkup::render($big, 0, max => 65536);
  ok(length($raised_html) > length($default_html),
    'render with max=>65536 produces a larger HTML body');
}

# Theme cookie helpers, no DB needed.
is(Iczelia::Theme::from_cookie({}), 'auto', 'no cookie -> auto');
is(Iczelia::Theme::from_cookie({cookies => {iczelia_theme => 'dark'}}),
  'dark', 'cookie=dark -> dark');
is(Iczelia::Theme::from_cookie({cookies => {iczelia_theme => 'neon'}}),
  'auto', 'invalid value -> auto');

# CachePolicy: the public git browser is HEAD-based and path-stable,
# so it bypasses the daemon response cache even without cookies.
is(bypass_for_request({
  method => 'GET', path => '/git/', cookies => {},
}), 1, '/git/ bypasses response cache');
is(bypass_for_request({
  method => 'GET', path => '/git/', cookies => {iczelia_theme => 'dark'},
}), 1, 'theme cookie: bypass cache');

# -- 2. Schema migration adds git_repos / git_commit_cache --------------------

my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
# schema.sql already includes the new tables; verify them.
ok(_table_has($db, 'git_repos'),        'git_repos table created');
ok(_table_has($db, 'git_commit_cache'), 'git_commit_cache table created');

# Migrate.pm should be a no-op on a fresh schema (idempotent).
my $applied = Iczelia::Migrate::run($db);
is($applied, 0, 'no migrations to run on fresh schema');

sub _table_has {
  my ($db, $name) = @_;
  return $db->one(
    q{SELECT 1 FROM sqlite_master WHERE type='table' AND name=?},
    $name
  ) ? 1 : 0;
}

# -- 3. Fake context for handler smoke tests ----------------------------------

{
  package FakeCache;
  sub new { bless { busts => [], prefixes => [] }, shift }
  sub bust        { push @{$_[0]{busts}}, $_[1]; }
  sub bust_prefix { push @{$_[0]{prefixes}}, $_[1]; }
  sub bust_many   { push @{$_[0]{busts}}, @_[1..$#_]; }
}
{
  package FakeCtx;
  use Iczelia::Template;
  use Iczelia::Render;
  use Iczelia::Tex;
  use Iczelia::Cache;
  sub new {
    my ($class, $db, %extra) = @_;
    require File::Path;
    File::Path::make_path("$extra{tmp}/tmp");
    my $tpl = Iczelia::Template->new(
      dirs => ["$FindBin::Bin/../share/templates"]
    );
    my $tex = Iczelia::Tex->new(
      db => $db, tmp_dir => "$extra{tmp}/tmp"
    );
    my $cache_real = Iczelia::Cache->new(db => $db);
    my $render = Iczelia::Render->new(
      db => $db, template => $tpl, tex => $tex,
      cache => $cache_real,
      cfg => { 'tmp-dir' => "$extra{tmp}/tmp" },
    );
    bless {
      db       => $db,
      cache    => FakeCache->new,
      cfg      => { 'tmp-dir' => $extra{tmp} . '/tmp' },
      template => $tpl,
      render   => $render,
      %extra,
    }, $class;
  }
  sub db       { $_[0]{db} }
  sub cache    { $_[0]{cache} }
  sub cfg      { $_[0]{cfg} }
  sub template { $_[0]{template} }
  sub render   { $_[0]{render} }
}

# Seed two repos: one empty, one with a mirror URL.
$db->do_(
  q{INSERT INTO git_repos(slug,title,owner,description,
       mirror_url,mirror_interval_s,created_at,updated_at)
       VALUES(?,?,?,?,?,?,?,?)},
  'empty', 'Empty Repo', 'kspalaiologos', 'an empty repo',
  undef, 3600, 1700000000, 1700000000
);
$db->do_(
  q{INSERT INTO git_repos(slug,title,owner,description,
       mirror_url,mirror_interval_s,created_at,updated_at)
       VALUES(?,?,?,?,?,?,?,?)},
  'mirror', 'Mirror Repo', 'iczelia', 'mirrored from github',
  'https://github.com/iczelia/example.git', 3600,
  1700000000, 1700000000
);

my $ctx = FakeCtx->new($db, tmp => "$tmp");

# /git/ index always renders, even without Git::Raw.
my $idx = Iczelia::Handlers::Git::_index($ctx,
  {method => 'GET', path => '/git/'});
is($idx->{status}, 200, '/git/ returns 200');
is($idx->{headers}{'Vary'}, 'Cookie',
  '/git/ varies on Cookie (tab preference)');
like($idx->{headers}{'Cache-Control'}, qr/\bno-store\b/,
  '/git/ stamps Cache-Control no-store');
ok($idx->{_no_cache}, '/git/ opts out of the response cache');
like($idx->{body}, qr{Empty Repo}, 'index lists Empty Repo');
like($idx->{body}, qr{Mirror Repo}, 'index lists Mirror Repo');
like($idx->{body}, qr{<title>iczelia :: git</title>},
  'index has expected title');
# Page chrome from layouts/page.tpl: about-page wrapper, iczelia logo,
# nav, vert.jpg energy line -- inherited from the existing site look.
like($idx->{body}, qr{<div class="about-page">},
  'index uses the about-page chrome');
like($idx->{body}, qr{/assets-1024x768/title\.gif},
  'index has the iczelia wordmark in the right sidebar');
like($idx->{body}, qr{/assets-about/vert\.jpg},
  'index has the energy line on the right');
# Layout swap: NO about-links nav-box element in the markup any more.
unlike($idx->{body}, qr{<nav class="nav-box"|<\w+ class="nav-box"},
  'index drops the about-links nav-box element');
# Lambda image must come BEFORE the wordmark in the right banner.
my ($idx_banner) = $idx->{body} =~ /(<div class="ab-banner">.*?<\/div>)/s;
my $idx_lpos = index($idx_banner // '', 'ab-lambda');
my $idx_tpos = index($idx_banner // '', 'ab-title');
ok(defined $idx_banner && $idx_lpos > 0 && $idx_tpos > $idx_lpos,
  'lambda image is stacked above the iczelia wordmark');
like($idx->{body}, qr{tab: ?<a href="\?set-tab=2"},
  'index has the tab-size toggle');

# Tab cookie write: ?set-tab=4 short-circuits to a redirect.
my $set = Iczelia::Handlers::Git::_index(
  $ctx,
  {method => 'GET', path => '/git/', qparams => {'set-tab' => '4'}}
);
is($set->{status}, 303, '?set-tab= -> 303 redirect');
ok($set->{cookies} && @{$set->{cookies}} == 1,
  'tab toggle writes one Set-Cookie');
like($set->{cookies}[0], qr/^iczelia_tab=4\b/, 'cookie value is 4');

# When the bare repo isn't on disk, summary still renders -- with an
# empty commits / branches / tags set. The page title falls back to
# the repo's display title (here "Empty Repo").
{
  my $sum = Iczelia::Handlers::Git::_summary(
    $ctx, {method => 'GET', path => '/git/empty/', caps => {slug => 'empty'}}
  );
  is($sum->{status}, 200,
    '/git/empty/ renders summary even without a bare repo on disk');
  like($sum->{body}, qr{<title>iczelia :: git :: Empty Repo</title>},
    'empty repo title threads through the chrome');
  like($sum->{body}, qr{no commits yet}, 'empty repo shows "no commits yet"');
}

# Unknown slug: 404 page rendered (still wrapped in our chrome).
my $nf = Iczelia::Handlers::Git::_summary(
  $ctx, {method => 'GET', path => '/git/nope/', caps => {slug => 'nope'}}
);
is($nf->{status}, 404, 'unknown slug -> 404');

# Mirror pump no-op when nothing is due.
$db->do_('UPDATE git_repos SET last_pulled_at = ? WHERE slug = ?',
  time + 86400, 'mirror');
my $n = Iczelia::Git::Mirrors::pump(
  db      => $db,
  var_dir => "$tmp",
  on_log  => sub { },
  max_jobs => 4,
);
is($n, 0, 'mirror pump: nothing due, zero processed');

# bare_repo_path containment guards.
{
  my $ok_path = eval { Iczelia::Git::bare_repo_path("$tmp", 'good-slug') };
  ok($ok_path && $ok_path =~ m{/git/good-slug\.git\z},
    'bare_repo_path composes inside var/git/');
  ok(!eval { Iczelia::Git::bare_repo_path("$tmp", '../escape'); 1 },
    'bare_repo_path rejects traversal attempts');
  ok(!eval { Iczelia::Git::bare_repo_path("$tmp", 'has slash'); 1 },
    'bare_repo_path rejects spaces');
  ok(!eval { Iczelia::Git::bare_repo_path("$tmp", '-leading-dash'); 1 },
    'bare_repo_path rejects leading dash');
}

# -- 4. Integration block: needs Git::Raw + libgit2 ---------------------------

SKIP: {
  skip 'Git::Raw not installed; live libgit2 tests skipped', 25
    unless Iczelia::Git::available();

  my $repo_path = "$tmp/repo.git";
  my $repo = Iczelia::Git::init_bare($repo_path);
  ok($repo, 'init_bare returned a repo');
  ok(-d "$repo_path/objects", 'bare repo dir exists');

  # Import a zip with text + binary + nested path.
  my $zip = make_zip(
    'README.md'  => "hello world\n",
    'run'        => "#!/usr/bin/env bash\necho ok\n",
    'src/main.c' => "int main(void) { return 0; }\n",
    'pic.png'    => "\x{89}PNG\r\n\x1a\nbinary",
  );
  my ($files, $zerr) = Iczelia::Subpages::extract_zip($zip);
  is($zerr, undef, 'zip extraction OK');
  my ($ok, $ierr) = Iczelia::Git::import_zip(
    $repo_path, $files,
    author_name  => 'Tester',
    author_email => 't@x',
    message      => 'initial',
  );
  ok($ok, "import_zip: " . ($ierr // 'ok')) or diag($ierr // '');

  $repo = Iczelia::Git::open_bare($repo_path);
  my $head = Iczelia::Git::head_sha($repo);
  like($head, qr/^[0-9a-f]{40}$/, 'HEAD is a 40-hex SHA');

  my $log = Iczelia::Git::log($repo, limit => 5);
  is(scalar @$log, 1, 'log returns one commit');
  is($log->[0]{subject}, 'initial', 'commit subject preserved');

  my $tree = Iczelia::Git::tree($repo, 'HEAD', '');
  my %names = map { $_->{name} => $_ } @$tree;
  ok($names{'README.md'} && $names{'README.md'}{type} eq 'file',
    'tree root: README.md is a file');
  ok($names{src} && $names{src}{type} eq 'dir',
    'tree root: src/ is a dir');

  my $src_tree = Iczelia::Git::tree($repo, 'HEAD', 'src');
  is(scalar @$src_tree, 1, 'src/ has one entry');
  is($src_tree->[0]{name}, 'main.c', 'src/main.c found');

  my ($bytes, $size, $sha) =
    Iczelia::Git::blob($repo, 'HEAD', 'README.md');
  is($bytes, "hello world\n", 'blob round-trips');
  is($size, 12, 'blob size matches');

  my $lc = Iczelia::Git::last_commit_for_path($repo, 'HEAD', 'src/main.c');
  ok($lc && $lc->{subject} eq 'initial',
    'last_commit_for_path returns the import commit');

  my $public = FakeCtx->new($db, tmp => "$tmp");
  # Seed a 'live' repo row whose on-disk path is $repo_path.
  $db->do_(
    q{INSERT INTO git_repos(slug,title,owner,description,
        mirror_url,mirror_interval_s,head_sha,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?)},
    'repo', 'R', 'me', '', undef, 3600, $head, time, time
  );
  # Stash the bare repo at the path Handlers::Git would compute.
  my $expected = Iczelia::Git::bare_repo_path("$tmp", 'repo');
  require File::Path;
  File::Path::make_path(_dirname($expected));
  system('cp', '-a', $repo_path, $expected) == 0 or die "cp: $?";

  my $sum = Iczelia::Handlers::Git::_summary(
    $public, {method => 'GET', path => '/git/repo/', caps => {slug => 'repo'}}
  );
  is($sum->{status}, 200, 'summary returns 200');
  like($sum->{body}, qr{recent commits}, 'summary lists recent commits');
  like($sum->{body}, qr{initial}, 'summary names the initial commit');
  like($sum->{body}, qr{git-readme}, 'summary renders the README block');
  # README placement: it must come AFTER the branches/tags section
  # (which now uses .ab-h2 since it lives in an .ab-section block).
  my $pos_branches = index($sum->{body}, 'branches</h2>');
  my $pos_readme   = index($sum->{body}, '<section class="git-readme');
  ok($pos_branches > 0 && $pos_readme > $pos_branches,
    'README is rendered below branches / tags');
  # Branches/tags list: table markup with auto-fit CSS columns and dates.
  like($sum->{body},
    qr{<table class="git-ref-table"><tbody><tr><td><a href="/git/repo/log/\?h=main">main</a> <span class="git-ref-time">\(<span class="git-age"[^>]*>\d{4}-\d{2}-\d{2} \d{2}:\d{2}</span>\)</span></td></tr></tbody></table>}s,
    'branches render as an auto-fit ref table with date');
  my @many_tags = map { +{ name => "v$_", ts => 1700000000 + $_ } } 1 .. 17;
  my $limited_refs = Iczelia::Handlers::Git::_ref_table(
    'repo', \@many_tags, 'tag',
    limit => 16, all_href => '/git/repo/tags/');
  like($limited_refs, qr{all tags &gt;&gt;},
    'long tag table gets a right-aligned all-tags link');
  like($limited_refs, qr{href="/git/repo/log/\?h=v16"},
    'summary ref table keeps the first sixteen refs');
  unlike($limited_refs, qr{href="/git/repo/log/\?h=v17"},
    'summary ref table hides refs beyond the sixteen-ref cap');
  # Site chrome: layouts/git.tpl wraps content + loads
  # about.compat.css (which carries the .hl-* highlighter palette +
  # Arial / LM Mono fonts).
  like($sum->{body}, qr{<div class="about-page">},
    'summary lives inside the about-page chrome');
  like($sum->{body}, qr{/about\.compat\.css},
    'summary loads the site stylesheet so fonts / .hl-* tokens apply');
  # Sidebar tab strip: summary marked active via qbtn-on.
  like($sum->{body},
    qr{<a class="qbtn qbtn-on" href="/git/repo/">summary</a>},
    'right-sidebar summary tab marked active (.qbtn-on)');
  like($sum->{body},
    qr{<a class="qbtn"\s+href="/git/repo/log/">log</a>},
    'right-sidebar log tab present, inactive (.qbtn only)');
  like($sum->{body},
    qr{<a class="qbtn"\s+href="/git/repo/tree/">tree</a>},
    'right-sidebar tree tab present, inactive (.qbtn only)');
  # Tab toggle present, default 2 marked active.
  like($sum->{body},
    qr{tab: ?<a href="\?set-tab=2" class="on">2</a>},
    'tab toggle present with default = 2');

  my $tr = Iczelia::Handlers::Git::_tree(
    $public, {method => 'GET', path => '/git/repo/tree/', caps => {slug => 'repo'}},
    ''
  );
  is($tr->{status}, 200, 'tree view returns 200');
  like($tr->{body}, qr{href="/git/repo/blob/README\.md"},
    'tree links to blob view');
  like($tr->{body}, qr{Last commit}, 'tree has Last commit column header');
  like($tr->{body},
    qr{<img src="/cms-icons/shell\.png" alt=""></td><td><a href="/git/repo/blob/run">run</a>},
    'tree icons use shebang-aware detection for extensionless scripts');

  my $bl = Iczelia::Handlers::Git::_blob(
    $public, {method => 'GET', path => '/git/repo/blob/src/main.c',
              caps => {slug => 'repo', path => 'src/main.c'}}
  );
  is($bl->{status}, 200, 'blob view returns 200');
  like($bl->{body}, qr{class="git-lines"},
    'blob view wraps highlighted code in a line-numbered table');
  like($bl->{body}, qr{class="git-lines hl lang-c"},
    'C file highlighted as C (lang-c class survives line wrapping)');
  like($bl->{body}, qr{<tr id="L1">},
    'first line gets id="L1" as an in-page anchor');
  like($bl->{body}, qr{<td class="ln"><a href="#L1">},
    'gutter line number is a clickable in-page link');
  my $wrapped_indent = Iczelia::Handlers::Git::_with_line_numbers(
    Iczelia::Highlight::highlight("int main(void) {\n  return 0;\n}\n", 'c')
  );
  like($wrapped_indent, qr{<td class="lc"><pre>\s\s<span class="hl-kw">return</span>},
    'line-number wrapper preserves leading indentation inside code cell');
  like($bl->{body}, qr{href="/git/repo/raw/src/main\.c"},
    'blob view links to raw');
  like($bl->{body}, qr{wrap: <a href="\?set-wrap=0" class="on">off</a><a href="\?set-wrap=1">on</a>},
    'blob view exposes word-wrap preference with off selected by default');
  my $bl_wrap = Iczelia::Handlers::Git::_blob(
    $public, {method => 'GET', path => '/git/repo/blob/src/main.c',
              caps => {slug => 'repo', path => 'src/main.c'},
              cookies => {iczelia_wrap => 1}}
  );
  like($bl_wrap->{body}, qr{white-space: pre-wrap; word-wrap: break-word;},
    'blob view applies word-wrap CSS when enabled');
  like($bl_wrap->{body}, qr{wrap: <a href="\?set-wrap=0">off</a><a href="\?set-wrap=1" class="on">on</a>},
    'blob view marks word-wrap on when enabled');

  my $raw = Iczelia::Handlers::Git::_raw(
    $public, {method => 'GET', path => '/git/repo/raw/README.md',
              caps => {slug => 'repo', path => 'README.md'}}
  );
  is($raw->{status}, 200, 'raw returns 200');
  is($raw->{body}, "hello world\n", 'raw byte-for-byte');
  like($raw->{headers}{'Cache-Control'}, qr/\bno-store\b/,
    'raw HEAD-based file response is no-store');
  ok($raw->{_no_cache}, 'raw response opts out of the response cache');

  # README sanitization: <!--RAWHTML--> must NOT punch raw HTML
  # through Markup's admin-trusted passthrough on a third-party
  # README. Build a second repo whose README tries to inject <script>.
  my $hostile = "# h1\n\n"
    . "![Reference screenshot](screenshot.png?raw=true \"Reference screenshot\")\n\n"
    . "<!--RAWHTML--><script>alert(1)</script><!--/RAWHTML-->\n";
  my $hb = "$tmp/hostile.git";
  Iczelia::Git::init_bare($hb);
  Iczelia::Git::import_zip($hb, [{path=>'README.md', content=>$hostile}],
    message=>'h');
  my $hhead = Iczelia::Git::head_sha($hb);
  $db->do_(q{INSERT INTO git_repos(slug,title,owner,description,
        mirror_url,mirror_interval_s,head_sha,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?)},
    'host','Host','x','',undef,3600,$hhead,time,time);
  my $hwant = Iczelia::Git::bare_repo_path("$tmp", 'host');
  system('cp','-a',$hb,$hwant) == 0 or die "cp: $?";
  my $hsum = Iczelia::Handlers::Git::_summary(
    $public, {method=>'GET', path=>'/git/host/', caps=>{slug=>'host'}});
  unlike($hsum->{body}, qr/<script\b/i,
    'README sanitisation: <script> in <!--RAWHTML--> is stripped');
  like($hsum->{body}, qr/&lt;script&gt;alert\(1\)&lt;\/script&gt;/,
    'README sanitisation: literal text shown escaped');
  like($hsum->{body},
    qr{src="/git/host/raw/screenshot\.png\?raw=true"[^>]*title="Reference screenshot"},
    'README relative image with query is rewritten to repo raw URL');

  # Tab cookie: ?set-tab=4 writes the cookie + 303-redirects.
  my $tabset = Iczelia::Handlers::Git::_summary($public,
    {method=>'GET', path=>'/git/repo/', caps=>{slug=>'repo'},
     qparams=>{'set-tab'=>'4'}});
  is($tabset->{status}, 303, '?set-tab=4 -> 303 redirect');
  like($tabset->{cookies}[0], qr/^iczelia_tab=4\b/,
    'cookie value is 4');
  # Carrying the cookie back marks 4 active and bakes tab-size: 4 into <pre>.
  my $tab4 = Iczelia::Handlers::Git::_blob(
    $public, {method=>'GET', path=>'/git/repo/blob/src/main.c',
              caps=>{slug=>'repo', path=>'src/main.c'},
              cookies=>{iczelia_tab=>'4'}});
  like($tab4->{body}, qr{tab-size: ?4},
    'blob CSS bakes in tab-size: 4 when cookie is set');
  like($tab4->{body}, qr{<a href="\?set-tab=4" class="on">4</a>}s,
    'tab toggle marks 4 as active when cookie is 4');
}

# Build an in-memory zip from { path => content }.
sub make_zip {
  my (%f) = @_;
  my @names = sort keys %f;
  my $out   = '';
  my $z = IO::Compress::Zip->new(\$out, Name => $names[0])
    or die "zip init: $ZipError";
  $z->print($f{$names[0]});
  for my $n (@names[1 .. $#names]) {
    $z->newStream(Name => $n) or die "zip newStream: $ZipError";
    $z->print($f{$n});
  }
  $z->close;
  return $out;
}

sub _dirname {
  my ($p) = @_;
  $p =~ s{/[^/]+\z}{};
  return $p;
}

done_testing();
