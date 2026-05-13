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

package Iczelia::Warmer;
use strict;
use warnings;
use Time::HiRes   qw();
use Carp          qw(croak);
use JSON::PP      ();
use Iczelia::Util qw(detect_cores);

use Iczelia::DB;
use Iczelia::Tex;
use Iczelia::Cache;
use Iczelia::Markup;
use Iczelia::SafeMarkup;
use Iczelia::Handlers::Admin::Cache qw(REBUILD_PHASE);

# Snapshot key updated at the start of each pass and again after
# rendering finishes; the admin dashboard reads it instead of walking.
use constant STATS_SETTING      => 'math.cache_stats';
use constant COMPRESS_PASS_BATCH => 50;

# Background tex_cache filler: walk every math source, fork N workers,
# render the misses, also drive the response_cache compress pass.

sub new {
  my ($class, %arg) = @_;
  croak "cfg required" unless $arg{cfg};
  bless {
    cfg           => $arg{cfg},
    idle_seconds  => $arg{idle_seconds}  // 60,
    startup_delay => $arg{startup_delay} // 0,
    workers       => $arg{workers} || detect_cores(),
    on_log        => $arg{on_log},
  }, $class;
}

sub run {
  my ($self) = @_;
  Time::HiRes::sleep($self->{startup_delay}) if $self->{startup_delay};
  while (1) {
    eval {$self->_pass};
    $self->_log("pass error: $@") if $@;
    Time::HiRes::sleep($self->{idle_seconds});
  }
}

# Synchronous one-shot pass: bin/iczelia-server runs this at boot,
# bin/iczelia-rebuild-cache runs it for scope=all. force=>1 bypasses
# the rebuild-phase guard since these callers _are_ the rebuild.
sub warmup {
  my ($self, %opt) = @_;
  return $self->_pass(force => 1, %opt);
}

sub _log {
  my ($self, $msg) = @_;
  if   ($self->{on_log}) {$self->{on_log}->($msg)}
  else                   {warn "[warmer] $msg\n"}
}

sub _connect {
  my ($self) = @_;
  my $db     = Iczelia::DB->connect($self->{cfg});
  my $tex    = Iczelia::Tex->new(
    db      => $db,
    tmp_dir => $self->{cfg}{'tmp-dir'},
  );
  return ($db, $tex);
}

sub _pass {
  my ($self, %opt) = @_;
  my ($db, $tex) = $self->_connect;

  unless ($opt{force}) {
    my $rebuild_phase = $db->setting(REBUILD_PHASE) // '';
    if ($rebuild_phase =~ /^(?:starting|math|html|cancelling)$/) {
      $db->disconnect;
      return 0;
    }
  }

  my ($missing_ref, $total) = _collect_missing($db, $tex);
  my @missing = @$missing_ref;
  _save_stats($db, $total, $total - scalar(@missing), scalar @missing);

  # Mirror per-fragment progress into caller-supplied settings keys so
  # the admin dashboard can show a live X/Y during the math phase.
  my $prog_key  = $opt{progress_key};
  my $total_key = $opt{total_key};
  if ($prog_key) {
    $db->set_setting($prog_key, 0);
    $db->set_setting($total_key, scalar @missing) if $total_key;
  }

  if (@missing) {
    my $n_workers = $self->{workers} || 1;
    $n_workers = scalar @missing if $n_workers > scalar @missing;
    my $started = Time::HiRes::time();
    $self->_log(sprintf "%d fragment(s) to warm; %d worker(s)",
      scalar(@missing), $n_workers);

    my $hdl = {};   # per-child cache; populated lazily on first task
    Iczelia::Util::fork_pool(
      tasks   => \@missing,
      workers => $n_workers,
      worker  => sub {
        my ($frag) = @_;
        ($hdl->{db}, $hdl->{tex}) = $self->_connect unless $hdl->{db};
        eval {$hdl->{tex}->render(@$frag)};
        $hdl->{db}->do_(
          'UPDATE settings SET value = CAST(value AS INTEGER) + 1
               WHERE key = ?', $prog_key
        ) if $prog_key;
      },
    );

    my $elapsed = Time::HiRes::time() - $started;
    $self->_log(sprintf "warmed %d fragment(s) in %.1fs",
      scalar(@missing), $elapsed);

    # Optimistic: render failures inflate "cached" until the next
    # walk corrects it.
    _save_stats($db, $total, $total, 0);
  }

  # Compress response_cache rows the request path stored raw.
  eval {
    my $cache = Iczelia::Cache->new(
      db      => $db,
      tmp_dir => $self->{cfg}{'tmp-dir'},
    );
    my $started = Time::HiRes::time();
    my $n       = $cache->compress_pending(limit => COMPRESS_PASS_BATCH);
    if ($n) {
      $self->_log(sprintf "compressed %d response cache row(s) in %.1fs",
        $n, Time::HiRes::time() - $started);
    }
    1;
  } or $self->_log("compress pass error: $@");

  $db->disconnect;
  return scalar @missing;
}

sub _save_stats {
  my ($db, $total, $cached, $missing) = @_;
  my $j = eval {
    JSON::PP::encode_json(
      {
        total   => $total + 0,
        cached  => $cached + 0,
        missing => $missing + 0,
        ts      => time,
      }
    );
  };
  return unless defined $j;
  eval {$db->set_setting(STATS_SETTING, $j); 1}
    or warn "[warmer] stats save: $@";
}

# Returns (\@missing, $total_distinct). One SELECT for all hashes,
# then a single in-memory check per fragment.
sub _collect_missing {
  my ($db, $tex) = @_;
  my %have;
  my $hashes = $db->col('SELECT hash FROM tex_cache');
  $have{$_} = 1 for @$hashes;

  my %seen;    # hash -> [display, tex] when missing, undef when cached
  my $check = sub {
    my ($display, $src) = @_;
    my $hash = $tex->cache_key($display, $src);
    return if exists $seen{$hash};
    $seen{$hash} = $have{$hash} ? undef : [$display, $src];
  };

  _walk_math($db, $check);

  my @missing = grep {defined} values %seen;
  return (\@missing, scalar keys %seen);
}

# Cheap dashboard stat: snapshot + COUNT(*). No live body walk.
sub stats {
  my ($class, $db, undef) = @_;
  my $rows = $db->one('SELECT COUNT(*) FROM tex_cache') // 0;
  my $j    = eval {$db->setting(STATS_SETTING)};
  my $snap;
  if (defined $j && length $j) {
    $snap = eval {JSON::PP::decode_json($j)};
  }
  return {
    total   => ($snap && defined $snap->{total})   ? $snap->{total} + 0   : 0,
    cached  => ($snap && defined $snap->{cached})  ? $snap->{cached} + 0  : 0,
    missing => ($snap && defined $snap->{missing}) ? $snap->{missing} + 0 : 0,
    cache_rows  => $rows,
    snapshot_at => $snap ? $snap->{ts} : undef,
  };
}

sub _walk_math {
  my ($db, $cb) = @_;

  my $bodies =
    $db->col("SELECT body FROM posts WHERE body IS NOT NULL AND body <> ''");
  for my $body (@$bodies) {
    my (undef, $math) = eval {Iczelia::Markup::render($body)};
    next unless $math && @$math;
    $cb->(@$_) for @$math;
  }

  my $gentries = $db->all(
    q{
        SELECT body_md, admin_reply_md
          FROM guestbook_entries
         WHERE approved_at IS NOT NULL AND rejected_at IS NULL}
  );
  for my $row (@$gentries) {
    for my $field (qw(body_md admin_reply_md)) {
      my $body = $row->{$field};
      next unless defined $body && length $body;
      my (undef, $math) = eval {Iczelia::SafeMarkup::render($body)};
      next unless $math && @$math;
      $cb->(@$_) for @$math;
    }
  }
}

1;
