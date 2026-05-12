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
use Iczelia::Content;
use Iczelia::Highlight;

package R;
sub new             {bless {}, shift}
sub invalidate_post { }
sub invalidate_page { }
sub invalidate_home { }
sub invalidate_all  { }

package main;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/test.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");
Iczelia::Highlight::set_db($db);

my $c = Iczelia::Content->new(db => $db, render => R->new);

# 1. Create a kotlin-ish language.
my ($id, $err) = $c->create_lang(
  {
    name          => 'kotlin',
    aliases       => 'kt',
    keywords      => 'fun val var return if else',
    types         => 'Int String Boolean',
    line_comment  => '//',
    string_quotes => '"',
  }
);
ok($id, 'kotlin created') or diag $err;

# Now Highlight::known should return 1, and highlight should colour
# 'fun', 'val', and 'Int'.
ok(Iczelia::Highlight::known('kotlin'), 'kotlin known');
ok(Iczelia::Highlight::known('kt'),     'kt alias known');

my $code = q{fun foo(): Int { val x = 1; return x }};
my $h    = Iczelia::Highlight::highlight($code, 'kotlin');
like($h, qr{<span class="hl-kw">fun</span>},  'fun highlighted as kw');
like($h, qr{<span class="hl-kw">val</span>},  'val highlighted as kw');
like($h, qr{<span class="hl-typ">Int</span>}, 'Int highlighted as type');
like($h, qr{lang-kotlin},                     'class includes lang-kotlin');

# 2. Trying to alias a built-in is rejected at save time.
my ($id2, $err2) = $c->create_lang(
  {
    name     => 'python',
    keywords => 'def class',
  }
);
ok(!$id2, 'cannot create row named python (built-in)');
like($err2, qr/reserved|in use/, 'helpful error');

# 3. Tokens with regex metachars are silently filtered.
my ($id3, $err3) = $c->create_lang(
  {
    name     => 'evil',
    keywords => '(a+)+',
  }
);
ok($id3, 'evil row created (with no usable kws)');
my $h2 = Iczelia::Highlight::highlight('aaa', 'evil');
unlike($h2, qr{hl-kw}, 'malicious regex token filtered out');

# 4. Update bumps version -> cache stamp invalidates.
my ($_id4, $err4) = $c->update_lang(
  $id,
  {
    name     => 'kotlin',
    keywords => 'fun val var return if else when',
  }
);
ok(!$err4, 'update succeeded');
my $h3 = Iczelia::Highlight::highlight('when (x) {}', 'kotlin');
like(
  $h3,
  qr{<span class="hl-kw">when</span>},
  'newly-added keyword highlights'
);

# 5. Delete.
$c->delete_lang($id);
ok(!Iczelia::Highlight::known('kotlin'), 'kotlin gone after delete');

done_testing;
