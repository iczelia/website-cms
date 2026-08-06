# iczelia.net - personal CMS and static site engine.
# Copyright (C) 2026 Kamila Szewczyk

use strict;
use warnings;
use Test::More;
use IO::Socket       ();
use Socket           qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes      qw(sleep);
use FindBin          ();
use lib "$FindBin::Bin/../lib";

# The test only exercises request timing.  Stub response compression so it
# is independent of optional XS codec versions installed on the host.
BEGIN {
  package Iczelia::Compress;
  sub is_compressible_ct {0}
  sub brotli             {undef}
  sub gzip_fast          {undef}
  $INC{'Iczelia/Compress.pm'} = __FILE__;
}

use Iczelia::HTTP   ();
use Iczelia::Server ();

# A socketpair avoids binding a network port.  The worker still needs a
# listener-shaped handle, so a pipe subclass hands it the worker endpoint
# from accept(); max-requests makes it accept exactly once.
socketpair(my $worker_socket, my $client,
  AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";
bless $worker_socket, 'IO::Socket';
bless $client,        'IO::Socket';
pipe(my $listener, my $listener_signal) or die "pipe: $!";
{
  package KeepaliveTestListener;
  our $accepted;
  sub accept {
    my $socket = $accepted;
    undef $accepted;
    return $socket;
  }
}
bless $listener, 'KeepaliveTestListener';
$KeepaliveTestListener::accepted = $worker_socket;

my $srv = Iczelia::Server->new(
  config => {
    'max-requests'      => 2,
    'keepalive-max'     => 10,
    'keepalive-timeout' => 0.15,
    'request-timeout'   => 2,
    'request-cap'       => 4096,
  },
  on_request => sub {Iczelia::HTTP::text('ok')},
);
$srv->{listener} = $listener;
$Iczelia::Server::SLOW_REQ_S = 10;

my $pid = fork();
defined $pid or die "fork: $!";
if ($pid == 0) {
  $srv->_worker_loop;
  exit 0;
}

close $listener;
close $listener_signal;
close $worker_socket;
$client->autoflush(1);

# Pipeline the start of the second request so it has started before the
# keep-alive idle deadline, then deliver the rest of its body after that
# deadline.  The idle timeout must not become the in-progress read timeout.
print {$client}
    "GET /first HTTP/1.1\r\nHost: test\r\n\r\n"
  . "POST /chunk HTTP/1.1\r\nHost: test\r\nContent-Length: 2\r\n\r\nx";
sleep 0.4;
local $SIG{PIPE} = 'IGNORE';
print {$client} 'y';
shutdown $client, 1;

my $wire = '';
while (1) {
  my $part = '';
  my $n = sysread($client, $part, 8192);
  last unless $n;
  $wire .= $part;
}
close $client;
waitpid($pid, 0);

my @statuses = $wire =~ /HTTP\/1\.1 (\d+)/g;
is_deeply(\@statuses, [200, 200],
  'slow body on reused connection gets the normal request timeout')
  or diag $wire;

done_testing;
