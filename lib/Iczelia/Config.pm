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
use File::Path    qw(make_path);
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
#   update-remote     git remote bin/iczelia-update fetches ('' = no fetch)
#   update-tag-prefix tag prefix selecting release tags (default: 'v')
#   update-restart-cmd  shell command run after a successful self-update
#   git-ssh-key       private key for ssh git mirrors ('' = ssh default)
#   git-ssh-known-hosts  known_hosts for those mirrors (default var/git/known_hosts)
#   git-ssh-strict    StrictHostKeyChecking: accept-new (default) | yes | no

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
  'update-remote'      => 'origin',
  'update-tag-prefix'  => 'v',
  'update-restart-cmd' => '',
  'git-ssh-key'          => '',
  'git-ssh-known-hosts'  => '',
  'git-ssh-strict'       => 'accept-new',
);

sub load {
  my ($class, $opt) = @_;
  $opt ||= {};

  my $self = {%DEFAULTS};

  if ($opt->{config} && -r $opt->{config}) {
    _read_file($self, $opt->{config});
    $self->{_config_path} = File::Spec->rel2abs($opt->{config});
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

  # Session/CSRF HMAC key. An explicit config or CLI value always wins;
  # otherwise it is persisted in a file beside the db so it stays stable
  # across restarts, backups, and wipes, and is shared by every preforked
  # worker (resolved once in the supervisor, inherited via fork). It must
  # never be sourced from the database: backups carry the settings table,
  # so a db-backed secret would rotate on every import and silently
  # invalidate every live session and CSRF token.
  $self->{'cookie-secret'} = _resolve_cookie_secret($self->{db})
    unless length $self->{'cookie-secret'};
}

# Path of the persistent secret: <state-dir>/cookie-secret, where
# state-dir is the directory holding the sqlite db. That keeps it on the
# same writable volume as the rest of the instance state and matches
# what deploy/entrypoint.sh seeds in the container.
sub _secret_file_for {
  my ($db_path) = @_;
  my ($vol, $dir) = File::Spec->splitpath($db_path);
  my $state = File::Spec->catpath($vol, $dir, '');
  $state = '.' unless length $state;
  return File::Spec->catfile($state, 'cookie-secret');
}

sub _resolve_cookie_secret {
  my ($db_path) = @_;
  my $file = _secret_file_for($db_path);

  if (-e $file) {
    open my $fh, '<', $file or croak "config: open $file: $!";
    local $/;
    my $hex = <$fh>;
    close $fh;
    $hex //= '';
    $hex =~ s/\s+//g;
    return $hex if length($hex) >= 64;
    croak "config: $file holds a short/empty secret (need >= 64 hex "
      . "chars); delete it to regenerate, or pin cookie-secret in config";
  }
  return _generate_cookie_secret($file);
}

# 32 CSPRNG bytes, hex-encoded, written 0600 via temp+rename so a
# half-written file can never be read. Runs once in the supervisor
# before any worker fork.
sub _generate_cookie_secret {
  my ($file) = @_;
  my ($vol, $dir) = File::Spec->splitpath($file);
  my $state = File::Spec->catpath($vol, $dir, '');
  make_path($state) if length($state) && !-d $state;

  open my $rnd, '<:raw', '/dev/urandom' or croak "config: /dev/urandom: $!";
  my $bytes = '';
  read($rnd, $bytes, 32) == 32
    or croak "config: short read from /dev/urandom";
  close $rnd;
  my $hex = unpack 'H*', $bytes;

  my $tmp = "$file.tmp.$$";
  open my $out, '>', $tmp or croak "config: write $tmp: $!";
  chmod 0600, $tmp;
  print {$out} $hex  or croak "config: write $tmp: $!";
  close $out         or croak "config: close $tmp: $!";
  rename $tmp, $file or croak "config: rename $tmp -> $file: $!";
  return $hex;
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
