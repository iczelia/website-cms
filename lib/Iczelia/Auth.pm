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

package Iczelia::Auth;
use strict;
use warnings;
use Carp          qw(croak);
use Digest::SHA   qw(hmac_sha256 hmac_sha256_hex);
use MIME::Base64  qw(encode_base64 decode_base64);
use Iczelia::HTTP ();
use Iczelia::Throttle;

# Single-admin authentication.
#   Password:  pbkdf2-sha256$<iter>$<b64-salt>$<b64-hash>
#   Session:   iczelia_sid=<sid>.<hmac>
#   CSRF:      HMAC(secret, sid . form_name)

use constant {
  PBKDF2_ITERS => 200_000,
  SALT_BYTES   => 16,
  KEY_BYTES    => 32,
  SID_BYTES    => 24,
  SESSION_TTL  => 7 * 24 * 60 * 60,
  COOKIE_NAME  => 'iczelia_sid',
};

sub new {
  my ($class, %arg) = @_;
  croak "db required"            unless $arg{db};
  croak "cookie_secret required" unless $arg{cookie_secret};
  my $secret_bytes = pack 'H*', $arg{cookie_secret};
  croak "cookie_secret must be at least 32 bytes (hex)"
    if length($secret_bytes) < 32;
  my $self = bless {
    db       => $arg{db},
    secret   => $secret_bytes,
    throttle => Iczelia::Throttle->new(
      db     => $arg{db},
      table  => 'login_throttle',
      max    => 20,
      window => 600,
    ),
  }, $class;

  # Prime now so the no-such-user path doesn't pay (and leak) the
  # mint cost on its first request.
  _dummy_pwhash();
  return $self;
}

sub hash_password {
  my ($class_or_self, $password) = @_;
  my $salt = _rand(SALT_BYTES);
  my $hash = _pbkdf2($password, $salt, PBKDF2_ITERS, KEY_BYTES);
  return sprintf(
    'pbkdf2-sha256$%d$%s$%s',
    PBKDF2_ITERS,
    encode_base64($salt, ''),
    encode_base64($hash, '')
  );
}

sub verify_password {
  my ($class_or_self, $password, $stored) = @_;
  return 0 unless defined $stored;
  my @p = split /\$/, $stored;
  return 0 unless @p == 4 && $p[0] eq 'pbkdf2-sha256';
  my $iter = $p[1] + 0;
  my $salt = decode_base64($p[2]);
  my $want = decode_base64($p[3]);
  my $got  = _pbkdf2($password, $salt, $iter, length $want);
  return _eq_const_time($got, $want);
}

# PBKDF2-HMAC-SHA256, single block - sufficient since dklen never
# exceeds the SHA-256 output size.
sub _pbkdf2 {
  my ($password, $salt, $iter, $dklen) = @_;
  croak "dklen too large for single-block pbkdf2" if $dklen > 32;
  my $u = hmac_sha256($salt . pack('N', 1), $password);
  my $t = $u;
  for (2 .. $iter) {
    $u = hmac_sha256($u, $password);
    $t = $t ^ $u;
  }
  return substr($t, 0, $dklen);
}

sub _eq_const_time {
  my ($a, $b) = @_;
  return 0 unless length $a == length $b;
  my $r = 0;
  for (my $i = 0; $i < length $a; $i++) {
    $r |= ord(substr($a, $i, 1)) ^ ord(substr($b, $i, 1));
  }
  return $r == 0 ? 1 : 0;
}

sub set_password {
  my ($self, $username, $password) = @_;
  my $h = $self->hash_password($password);
  $self->{db}->do_(
    q{INSERT INTO auth(username, pwhash) VALUES(?, ?)
          ON CONFLICT(username) DO UPDATE SET pwhash=excluded.pwhash},
    $username, $h
  );
  return 1;
}

sub login {
  my ($self, $username, $password, $ip) = @_;
  if (!$self->{throttle}->allow($ip)) {
    return (undef, 'throttled');
  }
  my $row =
    $self->{db}->row('SELECT pwhash FROM auth WHERE username=?', $username);
  my $ok;
  if ($row) {
    $ok = $self->verify_password($password, $row->{pwhash});
  }
  else {
    # Run a real PBKDF2 on the missing-user path so the response
    # time matches the present-user path (timing-channel guard).
    $self->verify_password($password, _dummy_pwhash());
    $ok = 0;
  }
  unless ($ok) {
    return (undef, 'bad_credentials');
  }

  # Don't reset on success: counters decay with the window, but a
  # guess shouldn't grant unlimited follow-ups.
  my $sid = _hex(_rand(SID_BYTES));
  my $now = time;
  $self->{db}->do_(
    q{INSERT INTO sessions(sid, username, expires_at, ip, created_at)
          VALUES(?,?,?,?,?)},
    $sid, $username, $now + SESSION_TTL, $ip, $now
  );
  return ($sid, undef);
}

# Pre-computed dummy hash so the no-such-user path takes the same
# wall time as a real verify (timing-channel guard).
my $DUMMY_PWHASH;

sub _dummy_pwhash {
  return $DUMMY_PWHASH if defined $DUMMY_PWHASH;
  my $salt = "\x00" x SALT_BYTES;
  my $hash = _pbkdf2('iczelia-no-such-user', $salt, PBKDF2_ITERS, KEY_BYTES);
  $DUMMY_PWHASH = sprintf(
    'pbkdf2-sha256$%d$%s$%s',
    PBKDF2_ITERS,
    encode_base64($salt, ''),
    encode_base64($hash, '')
  );
  return $DUMMY_PWHASH;
}

sub logout {
  my ($self, $sid) = @_;
  $self->{db}->do_('DELETE FROM sessions WHERE sid=?', $sid) if $sid;
  return 1;
}

# Calls $fn->($ctx, $req, @rest) for valid sessions, or redirects to
# /admin/login. The handler reads $req->{auth_user} / $req->{auth_sid}.
sub gate {
  my ($self, $fn, $ctx, $req, @rest) = @_;
  my ($user, $sid) = $self->current_user($req);
  return Iczelia::HTTP::redirect('/admin/login') unless $user;
  $req->{auth_user} = $user;
  $req->{auth_sid}  = $sid;
  return $fn->($ctx, $req, @rest);
}

sub route_gate {
  my ($self, $ctx) = @_;
  return sub {
    my ($fn, @extra) = @_;
    sub {$self->gate($fn, $ctx, $_[0], @extra)};
  };
}

# Returns undef on success or a 400 response on CSRF mismatch.
sub require_csrf {
  my ($self, $req, $form_name) = @_;
  my $tok = $req->{params}{csrf} // '';
  return undef
    if $self->verify_csrf($req->{auth_sid}, $form_name, $tok);
  return Iczelia::HTTP::error(400, 'csrf');
}

sub current_user {
  my ($self, $req) = @_;
  my $cookie = $req->{cookies}{+COOKIE_NAME} or return (undef, undef);
  my ($sid, $mac) = split /\./, $cookie, 2;
  return (undef, undef) unless defined $sid && defined $mac;
  my $expected = $self->_sign_sid($sid);
  return (undef, undef) unless _eq_const_time($mac, $expected);
  my $row = $self->{db}
    ->row('SELECT username, expires_at FROM sessions WHERE sid=?', $sid);
  return (undef, undef) unless $row;
  my $now = time;

  if ($row->{expires_at} < $now) {
    $self->{db}->do_('DELETE FROM sessions WHERE sid=?', $sid);
    return (undef, undef);
  }

  # Sliding renewal: extend the session once it's past its midpoint.
  if ($row->{expires_at} - $now < SESSION_TTL / 2) {
    $self->{db}->do_('UPDATE sessions SET expires_at=? WHERE sid=?',
      $now + SESSION_TTL, $sid);
  }
  return ($row->{username}, $sid);
}

# Set-Cookie value for a session. `Secure` is on when X-Forwarded-Proto
# from the upstream nginx is `https`.
sub session_cookie {
  my ($self, $sid, $req) = @_;
  my $value  = $sid eq '' ? '' : "$sid." . $self->_sign_sid($sid);
  my $secure = Iczelia::HTTP::is_https($req);
  return Iczelia::HTTP::make_cookie(
    name     => COOKIE_NAME,
    value    => $value,
    path     => '/admin',
    httponly => 1,
    samesite => 'Lax',
    secure   => $secure,
    max_age  => ($sid eq '' ? 0 : SESSION_TTL),
  );
}

sub _sign_sid {
  my ($self, $sid) = @_;
  return hmac_sha256_hex($sid, $self->{secret});
}

sub csrf_token {
  my ($self, $sid, $form) = @_;
  return hmac_sha256_hex(($sid // '') . '|' . ($form // ''), $self->{secret});
}

sub verify_csrf {
  my ($self, $sid, $form, $token) = @_;
  return 0 unless defined $token && length $token;
  my $expected = $self->csrf_token($sid, $form);
  return _eq_const_time($token, $expected);
}

# Anonymous CSRF for the public guestbook form: we mint a signed cookie
# value on first GET and verify it on POST.
sub anon_csrf_cookie {
  my ($self, $existing) = @_;
  if (defined $existing && $existing =~ /^([0-9a-f]+)\.([0-9a-f]+)$/) {
    my ($id, $mac) = ($1, $2);
    if (_eq_const_time($mac, hmac_sha256_hex($id, $self->{secret}))) {
      return ($existing, 0);
    }
  }
  my $id  = _hex(_rand(16));
  my $mac = hmac_sha256_hex($id, $self->{secret});
  return ("$id.$mac", 1);
}

sub anon_csrf_token {
  my ($self, $cookie_value, $form) = @_;
  my ($id) = split /\./, $cookie_value || '', 2;
  return '' unless defined $id;
  return hmac_sha256_hex($id . '|' . $form, $self->{secret});
}

sub verify_anon_csrf {
  my ($self, $cookie_value, $form, $token) = @_;
  my ($id, $mac) = split /\./, $cookie_value || '', 2;
  return 0 unless defined $id && defined $mac;
  return 0 unless _eq_const_time($mac, hmac_sha256_hex($id, $self->{secret}));
  return _eq_const_time($token,
    hmac_sha256_hex($id . '|' . $form, $self->{secret}));
}

sub _rand {
  my ($n) = @_;
  open my $fh, '<:raw', '/dev/urandom' or croak "/dev/urandom: $!";
  my $out = '';
  while (length($out) < $n) {
    my $chunk;
    my $r = sysread $fh, $chunk, $n - length($out);
    croak "/dev/urandom: $!"  if !defined $r;
    croak "/dev/urandom: EOF" if $r == 0;
    $out .= $chunk;
  }
  close $fh;
  return $out;
}

sub _hex {
  my $b = shift;
  return unpack 'H*', $b;
}

1;
