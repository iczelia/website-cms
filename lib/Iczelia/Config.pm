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

package Iczelia::Config;
use strict;
use warnings;
use Carp          qw(croak);
use File::Spec    ();
use FindBin       ();
use Iczelia::Util qw(detect_cores);

# Configuration schema:
#   listen-tcp        host:port for the TCP listener (empty disables)
#   listen-socket     unix-domain socket path
#   workers           prefork count
#   max-requests      requests per worker before recycle
#   request-cap       max request body bytes
#   db                sqlite db path
#   media-dir         uploads directory
#   tmp-dir           latex / cache scratch dir
#   share-dir         templates / web assets
#   chrome-dir        static visual chrome (CSS, fonts, asset packs)
#   cookie-secret     hex-encoded HMAC key (>= 32 bytes of material)
#   nginx-purge-url   optional loopback purge endpoint
#   update-remote     git remote bin/iczelia-update fetches ('' = local branch)
#   update-branch     branch bin/iczelia-update tracks (default: release)
#   update-restart-cmd  shell command run after a successful self-update

my %DEFAULTS = (
  'listen-tcp'         => '127.0.0.1:8731',
  'listen-socket'      => '',
  'workers'            => detect_cores(),
  'max-requests'       => 500,
  'request-cap'        => 8 * 1024 * 1024,
  'db'                 => '',
  'media-dir'          => '',
  'tmp-dir'            => '',
  'share-dir'          => '',
  'chrome-dir'         => '',
  'cookie-secret'      => '',
  'nginx-purge-url'    => '',
  'update-remote'      => 'origin',
  'update-branch'      => 'release',
  'update-restart-cmd' => '',
);

sub load {
  my ($class, $opt) = @_;
  $opt ||= {};

  my $self = {%DEFAULTS};

  if ($opt->{config} && -r $opt->{config}) {
    _read_file($self, $opt->{config});
  }

  $self->{'listen-tcp'}    = $opt->{listen}  if defined $opt->{listen};
  $self->{'listen-socket'} = $opt->{socket}  if defined $opt->{socket};
  $self->{workers}         = $opt->{workers} if defined $opt->{workers};

  _fill_defaults($self);
  _validate($self);

  bless $self, $class;
}

sub _read_file {
  my ($self, $path) = @_;
  open my $fh, '<', $path or croak "config: cannot open $path: $!";
  while (defined(my $line = <$fh>)) {
    chomp $line;
    $line                        =~ s/^\s+//;
    $line                        =~ s/\s+$//;
    next if $line eq '' || $line =~ /^#/;
    my ($k, $v) = split /\s*=\s*/, $line, 2;
    defined $v or croak "config: bad line: $line";
    $self->{$k} = $v;
  }
  close $fh;
}

sub _fill_defaults {
  my ($self) = @_;

  my $project_root = File::Spec->rel2abs("$FindBin::RealBin/..");

  $self->{'share-dir'}  ||= "$project_root/share";
  $self->{'chrome-dir'} ||= "$project_root/share/chrome";

  my $var = "$project_root/var";
  $self->{db}          ||= "$var/site.db";
  $self->{'media-dir'} ||= "$var/media";
  $self->{'tmp-dir'}   ||= "$var/tmp";

  if (!$self->{'cookie-secret'}) {
    my $secret_file = "$var/cookie-secret";
    if (-r $secret_file) {
      open my $fh, '<', $secret_file or croak "open $secret_file: $!";
      local $/;
      $self->{'cookie-secret'} = <$fh>;
      close $fh;
      $self->{'cookie-secret'} =~ s/\s+$//;
    }
  }
}

sub _validate {
  my ($self) = @_;
  croak "config: must specify listen-tcp or listen-socket"
    unless $self->{'listen-tcp'} || $self->{'listen-socket'};
  croak "config: workers must be >= 1"
    unless $self->{workers} >= 1;
  croak "config: request-cap too small"
    unless $self->{'request-cap'} >= 4096;
}

sub get {
  my ($self, $k) = @_;
  return $self->{$k};
}

1;
