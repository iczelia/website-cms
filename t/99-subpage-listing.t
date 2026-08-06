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

# directory_entries lists one directory's immediate children. It must
# scope to that directory's subtree (not scan the whole bundle) and must
# still language-detect listed files from their content head -- the perf
# fix fetched the 8 KB sniff for only the displayed files.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Subpages;
use Iczelia::Highlight;

my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

sub f {
  my ($path, $content) = @_;
  return {
    path         => $path,
    content      => $content,
    content_type => 'text/plain',
    size         => length($content),
    is_binary    => 0,
  };
}

my $modtxt = "# -*- mode: perl -*-\nmy \$x = 1;\n";
my $id     = Iczelia::Subpages::create($db, 'bundle', 'B', [
  f('a/b/deep.py',    "print('x')\n"),
  f('a/b/mod.txt',    $modtxt),
  f('a/shallow.js',   "let x = 1;\n"),
  f('aa/sibling.txt', "i am a sibling dir, do not bleed\n"),
  f('top.md',         "# hi\n"),
]);

sub names {
  [ map { $_->{type} eq 'dir' ? "$_->{name}/" : $_->{name} } @{ $_[0] } ];
}

# Root: immediate children only -- dirs (a/, aa/) first, then files.
my $root = Iczelia::Subpages::directory_entries($db, $id, '');
is_deeply(names($root), ['a/', 'aa/', 'top.md'],
  'root: immediate children only, dirs first');

# 'a/' lists ITS children only; sibling 'aa/*' must not bleed in via the
# range scan, and deep 'a/b/*' files must not appear here.
my $a = Iczelia::Subpages::directory_entries($db, $id, 'a');
is_deeply(names($a), ['b/', 'shallow.js'],
  "'a/' lists only its own children (no sibling 'aa/', no deep 'a/b/' files)");

# 'a/b/' lists its files, with language detection intact.
my $ab = Iczelia::Subpages::directory_entries($db, $id, 'a/b');
is_deeply(names($ab), ['deep.py', 'mod.txt'], "'a/b/' lists its files");

my %lang = map { $_->{name} => $_->{lang} }
  grep { $_->{type} eq 'file' } @$ab;

# lang must equal what lang_for_file gives for the same name + content head
# -- i.e. the sniff is still fetched for displayed files.
is($lang{'deep.py'},
  Iczelia::Highlight::lang_for_file('deep.py', "print('x')\n"),
  'extension-based language preserved');
is($lang{'mod.txt'},
  Iczelia::Highlight::lang_for_file('mod.txt', $modtxt),
  'content-head sniff (modeline) still applied');
isnt($lang{'mod.txt'}, Iczelia::Highlight::lang_for_filename('mod.txt'),
  'sniff actually changed the result vs filename-only (proves head was read)');

done_testing;
