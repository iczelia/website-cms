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

use Iczelia::DB;
use Iczelia::Template;
use Iczelia::Render;
use Iczelia::Fetcher;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
$db->apply_schema_file("$FindBin::Bin/../share/seed.sql");

my $tpl = Iczelia::Template->new(dirs => ["$FindBin::Bin/../share/templates"]);
my $r   = Iczelia::Render->new(db => $db, template => $tpl);

# Use a stub `curl` that returns canned fixture bytes.
my $stub = "$tmpdir/fakecurl";
{
  open my $fh, '>', $stub or die $!;
  print $fh <<'PERL';
#!/usr/bin/perl
use strict; use warnings;
my $url;
for (my $i = 0; $i <= $#ARGV; $i++) {
    if ($ARGV[$i] eq '--' && $i + 1 <= $#ARGV) { $url = $ARGV[$i+1]; last }
}
$url //= '';
my $fixtures_dir = $ENV{ICZELIA_FIXTURES} or die 'ICZELIA_FIXTURES unset';
my $fixname;
if ($url =~ /api\.github\.com/) { $fixname = 'github.json' }
elsif ($url =~ /tilde\.zone/)   { $fixname = 'mastodon.rss' }
elsif ($url =~ /bsky/)          { $fixname = 'bluesky.json' }
else                            { exit 1 }
open my $fh, '<:raw', "$fixtures_dir/$fixname" or do {
    print STDERR "no fixture $fixname\n"; exit 2;
};
local $/;
my $body = <$fh>;
close $fh;
binmode STDOUT;
print $body;
exit 0;
PERL
  close $fh;
  chmod 0755, $stub;
}

# Fixtures
my $fixtures = "$tmpdir/fixtures";
mkdir $fixtures;
{
  open my $fh, '>', "$fixtures/github.json" or die $!;
  print $fh <<'JSON';
[
  {"type":"PushEvent","repo":{"name":"iczelia/xpar"},
   "payload":{"commits":[{"sha":"abc123"}]},
   "created_at":"2026-04-20T10:00:00Z"},
  {"type":"PullRequestEvent","repo":{"name":"iczelia/pdgzip"},
   "payload":{"action":"opened","pull_request":{"number":42}},
   "created_at":"2026-04-15T10:00:00Z"},
  {"type":"WatchEvent","repo":{"name":"nginx/nginx"},
   "created_at":"2026-04-10T10:00:00Z"}
]
JSON
  close $fh;
}
{
  open my $fh, '>', "$fixtures/mastodon.rss" or die $!;
  print $fh <<'RSS';
<?xml version="1.0"?>
<rss version="2.0"><channel>
<title>iczelia</title>
<item>
<title><![CDATA[hello world!]]></title>
<link>https://tilde.zone/@iczelia/123</link>
<pubDate>Fri, 20 Apr 2026 10:00:00 +0000</pubDate>
</item>
<item>
<title><![CDATA[<p>another post</p>]]></title>
<link>https://tilde.zone/@iczelia/124</link>
<pubDate>Thu, 19 Apr 2026 10:00:00 +0000</pubDate>
</item>
</channel></rss>
RSS
  close $fh;
}
{
  open my $fh, '>', "$fixtures/bluesky.json" or die $!;
  print $fh <<'JSON';
{ "feed": [
    { "post": {
        "uri": "at://did:plc:xxx/app.bsky.feed.post/abcdef",
        "indexedAt": "2026-04-21T10:00:00Z",
        "record": { "text": "perl is having a moment", "createdAt": "2026-04-21T10:00:00Z" }
    } },
    { "post": {
        "uri": "at://did:plc:xxx/app.bsky.feed.post/ghijkl",
        "indexedAt": "2026-04-20T10:00:00Z",
        "record": { "text": "another", "reply": { "parent": {} }, "createdAt": "2026-04-20T10:00:00Z" }
    } }
] }
JSON
  close $fh;
}

# Configure handles
$db->set_setting('github.username',   'iczelia');
$db->set_setting('mastodon.feed_url', 'https://tilde.zone/iczelia.rss');
$db->set_setting('bluesky.handle',    'iczelia.bsky.social');

local $ENV{ICZELIA_FIXTURES} = $fixtures;

my $f = Iczelia::Fetcher->new(
  db        => $db,
  render    => $r,
  curl      => $stub,
  timeout_s => 5,
);

my $results = $f->run_all;
my %by;
for my $r (@$results) {$by{$r->{source}} = $r}

is($by{github}{status}, 'ok', 'github ok');
cmp_ok($by{github}{count}, '>=', 2, 'github count >= 2');

is($by{mastodon}{status}, 'ok', 'mastodon ok');
cmp_ok($by{mastodon}{count}, '>=', 1, 'mastodon count');

is($by{bluesky}{status}, 'ok', 'bluesky ok');
cmp_ok($by{bluesky}{count}, '==', 1, 'bluesky reply skipped');

# Verify rows landed in DB
my $rows =
  $db->all('SELECT source, text, url FROM activity ORDER BY source, position');
my %seen;
for my $row (@$rows) {push @{$seen{$row->{source}}}, $row}

is($seen{github}[0]{text}, 'pushed to iczelia/xpar', 'github first row');
like($seen{github}[0]{url},  qr{commit/abc123}, 'github commit url');
like($seen{github}[1]{text}, qr{opened pr in iczelia/pdgzip}, 'github pr');

like($seen{mastodon}[0]{text}, qr{last post: hello world}, 'mastodon text');
unlike($seen{mastodon}[1]{text}, qr{<p>}, 'mastodon html stripped');

like($seen{bluesky}[0]{text}, qr{perl is having a moment}, 'bluesky text');

# Re-run; should replace, not duplicate
$f->run_all;
my $count = $db->one('SELECT COUNT(*) FROM activity');
cmp_ok($count, '<', 12, 'no duplicates after second fetch');

done_testing;
