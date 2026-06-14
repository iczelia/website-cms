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

# End-to-end behaviour of the CSRF gate (require_csrf, the code path that
# emits "Bad Request: csrf") plus the cross-worker invariant: two Auth
# instances built from the SAME secret -- as preforked workers inherit it
# via fork -- must accept each other's tokens, sessions, and anon-CSRF
# cookies. Divergent secrets must NOT cross-verify (the failure mode that
# produced flaky CSRF when the key was sourced per-process).

use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin    ();
use lib "$FindBin::Bin/../lib";

use Iczelia::DB;
use Iczelia::Auth;

my $tmp = File::Temp->newdir;
my $db  = Iczelia::DB->connect("$tmp/t.db");
$db->apply_schema_file("$FindBin::Bin/../share/schema.sql");

my $secret = 'c' x 64;
my $worker_a = Iczelia::Auth->new(db => $db, cookie_secret => $secret);
my $worker_b = Iczelia::Auth->new(db => $db, cookie_secret => $secret);
my $stranger = Iczelia::Auth->new(db => $db, cookie_secret => 'd' x 64);

my $sid = 'sid-xyz';

# require_csrf reads $req->{params}{csrf} and $req->{auth_sid}. Model the
# request the dispatcher hands it. Pass csrf => undef to omit the field.
sub gate {
  my ($auth, $form, $tok) = @_;
  my %p;
  $p{csrf} = $tok if defined $tok;
  return $auth->require_csrf({auth_sid => $sid, params => \%p}, $form);
}

my $good = $worker_a->csrf_token($sid, 'backup:import');

# --- happy paths ---------------------------------------------------------
is(gate($worker_a, 'backup:import', $good), undef,
  'same worker: valid token passes the gate');
is(gate($worker_b, 'backup:import', $good), undef,
  'cross worker: token minted by A passes on B (shared secret)');

# --- rejection paths: each must be a 400 "Bad Request: csrf" -------------
for my $case (
  ['wrong form name',   sub {gate($worker_a, 'backup:wipe',   $good)}],
  ['missing csrf field', sub {gate($worker_a, 'backup:import', undef)}],
  ['empty csrf field',  sub {gate($worker_a, 'backup:import', '')}],
  ['tampered token',    sub {gate($worker_a, 'backup:import', $good . 'ff')}],
  ['divergent secret',  sub {gate($stranger, 'backup:import', $good)}],
  )
{
  my ($name, $run) = @$case;
  my $r = $run->();
  ok($r, "reject: $name -> response returned");
  is($r->{status}, 400, "reject: $name -> 400") if ref $r;
  like($r->{body}, qr/csrf/, "reject: $name -> body mentions csrf") if ref $r;
}

# A token is bound to its sid: a different session can't reuse it.
{
  my $r = $worker_a->require_csrf(
    {auth_sid => 'other-sid', params => {csrf => $good}}, 'backup:import');
  ok($r && $r->{status} == 400, 'token bound to sid: other session rejected');
}

# --- session cookies share the secret across workers --------------------
$worker_a->set_password('admin', 'hunter2');
my ($login_sid, $lerr) = $worker_a->login('admin', 'hunter2', '127.0.0.1');
ok($login_sid, 'login on worker A') or diag $lerr;
my $cookie = $worker_a->session_cookie($login_sid);
$cookie =~ /iczelia_sid=([^;]+)/;
my ($user_b) = $worker_b->current_user({cookies => {iczelia_sid => $1}});
is($user_b, 'admin', 'session cookie minted by A validates on B');

# --- anonymous (guestbook) CSRF shares the secret too -------------------
my ($anon_cookie, $set) = $worker_a->anon_csrf_cookie(undef);
is($set, 1, 'anon cookie minted on first call');
my $anon_tok = $worker_a->anon_csrf_token($anon_cookie, 'guestbook');
ok($worker_b->verify_anon_csrf($anon_cookie, 'guestbook', $anon_tok),
  'anon-CSRF token from A verifies on B');
ok(!$stranger->verify_anon_csrf($anon_cookie, 'guestbook', $anon_tok),
  'anon-CSRF token rejected under a divergent secret');

done_testing;
