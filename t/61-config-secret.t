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

# The session/CSRF HMAC secret must be persistent and independent of the
# database. It used to be sourced from settings.auth.cookie_secret, which
# a backup import overwrites -- so every import silently rotated the
# secret and invalidated every live session and CSRF token. It now lives
# in a file beside the db. These tests pin that contract down.

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::Config;
use Iczelia::Auth;
use Iczelia::DB;

my $dir   = File::Temp->newdir;
my $state = "$dir/state";
mkdir $state or die "mkdir $state: $!";
my $db_path     = "$state/site.db";
my $secret_file = "$state/cookie-secret";

# Minimal config file pointing the db at our temp state dir.
sub write_cfg {
  my (%extra) = @_;
  my $path = "$dir/iczelia.conf";
  open my $fh, '>', $path or die $!;
  print {$fh} "db = $db_path\n";
  print {$fh} "$_ = $extra{$_}\n" for sort keys %extra;
  close $fh;
  return $path;
}

sub slurp {
  my ($p) = @_;
  open my $fh, '<', $p or die "open $p: $!";
  local $/;
  my $c = <$fh>;
  close $fh;
  $c =~ s/\s+//g;
  return $c;
}

# 1. First load generates the secret file beside the db.
my $cfg1 = Iczelia::Config->load({config => write_cfg()});
ok(-e $secret_file, 'cookie-secret file generated beside the db');
my $hex1 = $cfg1->get('cookie-secret');
like($hex1, qr/^[0-9a-f]{64}$/, 'resolved secret is 64 hex chars');
is(slurp($secret_file), $hex1, 'file content matches the resolved secret');
is((stat $secret_file)[2] & 07777, 0600, 'secret file is mode 0600');

# 2. Stable across reloads (process restarts): same secret comes back.
my $cfg2 = Iczelia::Config->load({config => write_cfg()});
is($cfg2->get('cookie-secret'), $hex1, 'secret is stable across reloads');

# 3. Independent of db CONTENT. Replace the db file outright (what an
#    import & replace does) -- the secret must not change.
unlink $db_path if -e $db_path;
open my $touch, '>', $db_path or die $!;
close $touch;
my $cfg3 = Iczelia::Config->load({config => write_cfg()});
is($cfg3->get('cookie-secret'), $hex1,
  'secret survives db replacement (import-proof)');

# 4. An explicit pin in config always wins over the file.
my $pin  = 'b' x 64;
my $cfg4 = Iczelia::Config->load({config => write_cfg('cookie-secret' => $pin)});
is($cfg4->get('cookie-secret'), $pin, 'explicit cookie-secret overrides file');

# 5. The resolved secret is usable by Auth and round-trips a real token.
my $adb = Iczelia::DB->connect("$dir/auth.db");
$adb->apply_schema_file("$FindBin::Bin/../share/schema.sql");
my $auth = Iczelia::Auth->new(db => $adb, cookie_secret => $hex1);
my $tok  = $auth->csrf_token('sid-123', 'backup:import');
ok($auth->verify_csrf('sid-123', 'backup:import', $tok),
  'resolved secret yields a verifiable CSRF token');

# 6. A short/garbage secret file is rejected loudly rather than silently
#    falling back to a weak or divergent key.
{
  my $bad = "$dir/bad";
  mkdir $bad;
  open my $fh, '>', "$bad/cookie-secret" or die $!;
  print {$fh} "tooshort";
  close $fh;
  open my $cf, '>', "$dir/bad.conf" or die $!;
  print {$cf} "db = $bad/site.db\n";
  close $cf;
  eval { Iczelia::Config->load({config => "$dir/bad.conf"}) };
  like($@, qr/short|hex/i, 'short secret file croaks');
}

done_testing;
