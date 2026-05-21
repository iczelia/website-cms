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

package Iczelia::DB;
use strict;
use warnings;
use DBI  ();
use Carp qw(croak);

# Thin DBI wrapper for SQLite with a prepared-statement cache.
# do_/row/one/all/col are shape shortcuts; tx[_immediate] wrap a cb
# in BEGIN [IMMEDIATE]/COMMIT, rolling back on die.

sub connect {
  my ($class, $cfg) = @_;
  my $path = ref $cfg ? $cfg->{db} : $cfg;
  croak "DB: missing db path" unless $path;
  my $self = bless {path => $path, cache => {}, pid => 0}, $class;
  _open($self);
  return $self;
}

sub _open {
  my ($self) = @_;
  my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$self->{path}",
    '', '',
    {
      RaiseError                       => 1,
      PrintError                       => 0,
      AutoCommit                       => 1,
      sqlite_unicode                   => 1,
      sqlite_allow_multiple_statements => 1,
    }
  ) or croak "DB: connect $self->{path}: $DBI::errstr";
  $dbh->do('PRAGMA foreign_keys = ON');
  $dbh->do('PRAGMA journal_mode = WAL');
  $dbh->do('PRAGMA synchronous = NORMAL');
  $dbh->do('PRAGMA busy_timeout = 5000');

  # Read perf: 256 MB mmap window so hot pages serve from page cache,
  # 64 MB per-connection page cache (negative = KiB).
  $dbh->do('PRAGMA mmap_size = 268435456');
  $dbh->do('PRAGMA cache_size = -65536');

  # Queries that don't write get to skip the writer-lock dance.
  $dbh->do('PRAGMA temp_store = MEMORY');
  $self->{dbh}   = $dbh;
  $self->{cache} = {};
  $self->{pid}   = $$;
  return $self;
}

# Required after fork(): children must not share the parent's fd.
sub reconnect {
  my ($self) = @_;
  if ($self->{dbh}) {
    eval {$self->{dbh}->{InactiveDestroy} = 1; $self->{dbh}->disconnect};
  }
  %{$self->{cache}} = ();
  delete $self->{dbh};
  return _open($self);
}

sub dbh {
  my ($self) = @_;
  if ($self->{pid} != $$) {$self->reconnect}
  return $self->{dbh};
}

sub _prep {
  my ($self, $sql) = @_;
  my $dbh = $self->dbh;
  return $self->{cache}{$sql} ||= $dbh->prepare($sql);
}

sub do_ {
  my ($self, $sql, @bind) = @_;
  my $sth = $self->_prep($sql);
  $sth->execute(@bind);
  return $sth->rows;
}

sub row {
  my ($self, $sql, @bind) = @_;
  my $sth = $self->_prep($sql);
  $sth->execute(@bind);
  my $r = $sth->fetchrow_hashref;
  $sth->finish;
  return $r;
}

sub one {
  my ($self, $sql, @bind) = @_;
  my $sth = $self->_prep($sql);
  $sth->execute(@bind);
  my @row = $sth->fetchrow_array;
  $sth->finish;
  return $row[0];
}

sub all {
  my ($self, $sql, @bind) = @_;
  my $sth = $self->_prep($sql);
  $sth->execute(@bind);
  my @out;
  while (my $r = $sth->fetchrow_hashref) {push @out, $r}
  return \@out;
}

sub col {
  my ($self, $sql, @bind) = @_;
  my $sth = $self->_prep($sql);
  $sth->execute(@bind);
  my @out;
  while (my @r = $sth->fetchrow_array) {push @out, $r[0]}
  return \@out;
}

sub last_id {$_[0]->dbh->sqlite_last_insert_rowid}

# A COMMIT or ROLLBACK that itself fails leaves the handle stuck in an
# open transaction, holding the write lock for every later request this
# worker serves. When that happens, drop the handle so the next request
# starts on a clean connection instead of inheriting a wedged lock.
sub tx {
  my ($self, $cb) = @_;
  my $dbh = $self->dbh;
  $dbh->begin_work;
  my $r = eval {$cb->($self)};
  if (my $e = $@) {
    eval {$dbh->rollback};
    $self->reconnect unless $dbh->{AutoCommit};
    die $e;
  }
  eval {$dbh->commit; 1} or do {
    my $e = $@;
    eval {$dbh->rollback};
    $self->reconnect unless $dbh->{AutoCommit};
    die $e;
  };
  return $r;
}

# For read-then-write that must be atomic across workers
# (throttle counters, post-revision snapshots). The raw BEGIN keeps
# DBI's AutoCommit at 1, so a failed ROLLBACK is the wedge signal here.
sub tx_immediate {
  my ($self, $cb) = @_;
  my $dbh = $self->dbh;
  $dbh->do('BEGIN IMMEDIATE');
  my $r = eval {$cb->($self)};
  if (my $e = $@) {
    eval {$dbh->do('ROLLBACK'); 1} or $self->reconnect;
    die $e;
  }
  eval {$dbh->do('COMMIT'); 1} or do {
    my $e = $@;
    eval {$dbh->do('ROLLBACK'); 1} or $self->reconnect;
    die $e;
  };
  return $r;
}

sub apply_schema_file {
  my ($self, $path) = @_;
  open my $fh, '<:raw', $path or croak "DB: open $path: $!";
  local $/;
  my $sql = <$fh>;
  close $fh;

  # The connect-time pragma lets us hand the file to sqlite whole,
  # including CREATE TRIGGER bodies with nested `;`.
  $self->dbh->do($sql);
  return 1;
}

sub disconnect {
  my ($self) = @_;
  %{$self->{cache}} = ();
  $self->{dbh}->disconnect if $self->{dbh};
  delete $self->{dbh};
}

sub setting {
  my ($self, $k, $default) = @_;
  my $v = $self->one('SELECT value FROM settings WHERE key=?', $k);
  return defined $v ? $v : $default;
}

sub set_setting {
  my ($self, $k, $v) = @_;
  $self->do_(
    'INSERT INTO settings(key,value) VALUES(?,?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value', $k, $v
  );
}

1;
