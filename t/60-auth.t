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
use Iczelia::Auth;

my $tmpdir = File::Temp->newdir;
my $db     = Iczelia::DB->connect("$tmpdir/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $secret = 'a' x 64;    # 32 bytes hex
my $auth   = Iczelia::Auth->new(db => $db, cookie_secret => $secret);

# 1: hash + verify
my $h = $auth->hash_password('hunter2');
ok($auth->verify_password('hunter2',  $h), 'verify good');
ok(!$auth->verify_password('hunter3', $h), 'verify bad');

# 2: set + login + current_user
$auth->set_password('admin', 'hunter2');

my ($sid, $err) = $auth->login('admin', 'hunter2', '127.0.0.1');
ok($sid, 'login returns sid') or diag $err;
is($err, undef, 'no error');

my $cookie = $auth->session_cookie($sid);
like($cookie, qr/iczelia_sid=$sid\.[0-9a-f]+/, 'cookie has signed sid');

my $req =
  {cookies =>
    {iczelia_sid => "$sid." . substr($cookie, length("iczelia_sid=$sid."))}};

# Extract the mac portion only:
$cookie =~ /iczelia_sid=([^;]+)/;
$req->{cookies}{iczelia_sid} = $1;
my ($u, $sid2) = $auth->current_user($req);
is($u,    'admin', 'current_user returns admin');
is($sid2, $sid,    'sid round-trip');

# 3: bad password
my ($s2, $e2) = $auth->login('admin', 'wrong', '127.0.0.1');
is($s2, undef,             'wrong password returns undef sid');
is($e2, 'bad_credentials', 'bad_credentials');

# 4: throttle after many attempts
for (1 .. 25) {$auth->login('admin', 'wrong', '10.0.0.1')}
my ($s3, $e3) = $auth->login('admin', 'hunter2', '10.0.0.1');
is($s3, undef,       'throttled');
is($e3, 'throttled', 'throttle reason');

# 5: csrf
my $tok = $auth->csrf_token($sid, 'edit');
ok($auth->verify_csrf($sid,  'edit',  $tok), 'csrf verifies');
ok(!$auth->verify_csrf($sid, 'other', $tok), 'csrf rejects wrong form');

# 6: anon csrf
my ($cv, $set) = $auth->anon_csrf_cookie(undef);
like($cv, qr/^[0-9a-f]+\.[0-9a-f]+$/, 'anon cookie format');
is($set, 1, 'set on first call');
my ($cv2, $set2) = $auth->anon_csrf_cookie($cv);
is($cv,   $cv2, 'reuse same cookie');
is($set2, 0,    'no resend');

my $atok = $auth->anon_csrf_token($cv, 'login');
ok($auth->verify_anon_csrf($cv, 'login', $atok), 'anon token verifies');

# 7: logout
$auth->logout($sid);
my ($u2) = $auth->current_user($req);
is($u2, undef, 'after logout, no user');

done_testing;
