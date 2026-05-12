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
use IO::Handle;

use_ok('Iczelia::HTTP');

# Build an in-memory pipe so HTTP::read_request can sysread from it.
sub mkreader {
  my ($bytes) = @_;
  pipe(my $r, my $w) or die "pipe: $!";
  binmode $w;
  syswrite $w, $bytes;
  close $w;
  return $r;
}

# 1: simple GET
{
  my $raw =
    "GET /about/?x=1 HTTP/1.1\r\nHost: ex.com\r\nUser-Agent: t/1\r\n\r\n";
  my $req = Iczelia::HTTP::read_request(mkreader($raw));
  is($req->{method},        'GET',     'method GET');
  is($req->{path},          '/about/', 'path');
  is($req->{query},         'x=1',     'query');
  is($req->{qparams}{x},    '1',       'qparams x');
  is($req->{headers}{host}, 'ex.com',  'host header lc');
}

# 2: POST urlencoded
{
  my $body = 'a=1&b=hello%20world';
  my $raw =
      "POST /admin/save HTTP/1.1\r\nHost: ex\r\n"
    . "Content-Type: application/x-www-form-urlencoded\r\n"
    . "Content-Length: "
    . length($body)
    . "\r\n\r\n"
    . $body;
  my $req = Iczelia::HTTP::read_request(mkreader($raw));
  is($req->{method},     'POST',        'POST');
  is($req->{fparams}{a}, '1',           'form a');
  is($req->{fparams}{b}, 'hello world', 'form b decoded');
}

# 3: cookies
{
  my $raw = "GET / HTTP/1.1\r\nHost: ex\r\nCookie: foo=bar; baz=qux\r\n\r\n";
  my $req = Iczelia::HTTP::read_request(mkreader($raw));
  is($req->{cookies}{foo}, 'bar', 'cookie foo');
  is($req->{cookies}{baz}, 'qux', 'cookie baz');
}

# 4: multipart form
{
  my $b = "------BoundaryX";
  my $body =
      "$b\r\n"
    . "Content-Disposition: form-data; name=\"title\"\r\n\r\n"
    . "hello\r\n"
    . "$b\r\n"
    . "Content-Disposition: form-data; name=\"file\"; filename=\"x.txt\"\r\n"
    . "Content-Type: text/plain\r\n\r\n"
    . "ABCDEF\r\n"
    . "$b--\r\n";
  my $raw =
      "POST /upload HTTP/1.1\r\nHost: ex\r\n"
    . "Content-Type: multipart/form-data; boundary=----BoundaryX\r\n"
    . "Content-Length: "
    . length($body)
    . "\r\n\r\n"
    . $body;
  my $req = Iczelia::HTTP::read_request(mkreader($raw));
  is($req->{fparams}{title},       'hello',  'multipart text field');
  is(scalar @{$req->{uploads}},    1,        'one upload');
  is($req->{uploads}[0]{filename}, 'x.txt',  'upload filename');
  is($req->{uploads}[0]{body},     'ABCDEF', 'upload body');
}

# 5: oversized body
{
  my $body = 'x' x 1000;
  my $raw = "POST / HTTP/1.1\r\nHost: ex\r\nContent-Length: 1000\r\n\r\n$body";
  my $req = Iczelia::HTTP::read_request(mkreader($raw), cap => 100);
  ok($req->{_bad}, 'oversized body rejected');
  is($req->{_status}, 413, 'status 413');
}

done_testing;
