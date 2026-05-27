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

package Iczelia::App;
use strict;
use warnings;

use Iczelia::DB;
use Iczelia::Migrate;
use Iczelia::Template;
use Iczelia::Render;
use Iczelia::Router;
use Iczelia::Tex;
use Iczelia::Auth;
use Iczelia::Cache;
use Iczelia::Fetcher;
use Iczelia::Schema;
use Iczelia::Content;
use Iczelia::Highlight;
use Iczelia::Warmer;
use Iczelia::Context;
use Iczelia::Handlers::Public;
use Iczelia::Handlers::Admin;
use Iczelia::Handlers::Guestbook;
use Iczelia::Handlers::Feeds;
use Iczelia::Handlers::OG;
use Iczelia::Handlers::Static;
use Iczelia::Handlers::Honeypot;
use Iczelia::Handlers::Dynamic;
use Iczelia::Handlers::Subpages;
use Iczelia::Handlers::Git;
use Iczelia::Handlers::Analytics;
use Iczelia::Handlers::Backup;
use Iczelia::Slop;
use File::Path qw(make_path);

sub build {
  my ($class, $cfg) = @_;
  my $db = Iczelia::DB->connect($cfg);

  # Auto-migrate the schema. Runs once in the supervisor before any
  # worker fork; idempotent. A fresh DB without `posts` is skipped
  # (iczelia-init applies the base schema separately); existing DBs
  # that pre-date a new column get ALTERed in here so an in-place
  # `podman pull && systemctl restart` is enough.
  Iczelia::Migrate::run($db);

  Iczelia::Highlight::set_db($db);
  my $tpl =
    Iczelia::Template->new(dirs => [$cfg->{'share-dir'} . '/templates'],);
  -d $cfg->{'tmp-dir'} or make_path($cfg->{'tmp-dir'});
  my $tex = Iczelia::Tex->new(
    db      => $db,
    tmp_dir => $cfg->{'tmp-dir'},
  );
  my $cache = Iczelia::Cache->new(
    db      => $db,
    tmp_dir => $cfg->{'tmp-dir'},
  );
  my $rnd = Iczelia::Render->new(
    db       => $db,
    template => $tpl,
    tex      => $tex,
    cache    => $cache,
    cfg      => $cfg,
  );
  my $auth = Iczelia::Auth->new(
    db            => $db,
    cookie_secret => $cfg->{'cookie-secret'} || _shared_secret($db),
  );
  my $fetcher =
    Iczelia::Fetcher->new(db => $db, render => $rnd, cache => $cache);
  my $schema = Iczelia::Schema->new(
    dir => $cfg->{'share-dir'} . '/templates/pages',
  );
  my $content = Iczelia::Content->new(db => $db, render => $rnd);

  my $router = Iczelia::Router->new;
  my $ctx    = Iczelia::Context->new(
    cfg      => $cfg,
    db       => $db,
    template => $tpl,
    render   => $rnd,
    auth     => $auth,
    cache    => $cache,
    fetcher  => $fetcher,
    schema   => $schema,
    content  => $content,
  );
  Iczelia::Handlers::Static->register($router, $ctx);
  Iczelia::Handlers::Honeypot->register($router, $ctx);
  Iczelia::Handlers::Feeds->register($router, $ctx);
  Iczelia::Handlers::OG->register($router, $ctx);
  Iczelia::Handlers::Guestbook->register($router, $ctx);
  Iczelia::Handlers::Public->register($router, $ctx);
  Iczelia::Handlers::Git->register($router, $ctx);
  Iczelia::Handlers::Admin->register($router, $ctx);
  Iczelia::Handlers::Analytics->register($router, $ctx);
  Iczelia::Handlers::Backup->register($router, $ctx);

  # Tried in order before a 404: admin-defined dynamic pages, then
  # static subpage bundles.
  my $dynamic_lookup = sub {
    my ($req) = @_;
    return Iczelia::Handlers::Dynamic::lookup($ctx, $req)
      || Iczelia::Handlers::Subpages::serve($ctx, $req);
  };

  my $not_found = sub {
    my ($req) = @_;
    my $html = eval {$rnd->render_not_found($req)};
    return undef unless $html;
    return Iczelia::HTTP::html($html, status => 404);
  };

  # Warmer is forked off the supervisor; it owns its own DB / Tex
  # handles and forks N children of its own to render in parallel.
  my $warmer_cb = sub {
    Iczelia::Warmer->new(cfg => $cfg)->run;
  };

  # AI-slop bot trap. Load weights here (pre-fork) so the kernel can
  # COW-share the ~52 MB model across every worker; if the share/tinyllm
  # directory is absent the loader just no-ops and the trap serves
  # stubs instead of generated slop.
  my $slop = Iczelia::Slop->new(db => $db, cfg => $cfg);
  eval {$slop->ensure_loaded};
  warn "slop: ensure_loaded failed: $@" if $@;
  my $pre_dispatch = sub {
    my ($req) = @_;
    return $slop->maybe_serve($req);
  };

  return {
    ctx            => $ctx,
    router         => $router,
    dynamic_lookup => $dynamic_lookup,
    not_found      => $not_found,
    warmer         => $warmer_cb,
    pre_dispatch   => $pre_dispatch,
  };
}

# Settings-backed fallback when the operator hasn't pinned a secret in
# config. INSERT OR IGNORE means concurrent workers converge on one
# value; every worker reads the same string so cookies validate
# regardless of which worker minted them.
sub _shared_secret {
  my ($db) = @_;
  my $existing = $db->setting('auth.cookie_secret');
  return $existing if defined $existing && length($existing) >= 64;
  open my $fh, '<:raw', '/dev/urandom' or die "/dev/urandom: $!";
  my $b;
  sysread $fh, $b, 32;
  close $fh;
  my $hex = unpack 'H*', $b;
  $db->do_(q{INSERT OR IGNORE INTO settings(key, value) VALUES(?, ?)},
    'auth.cookie_secret', $hex);

  # Re-read so we converge on whoever's INSERT won the race; fall
  # back to our locally-minted value if the read returns nothing
  # (settings table wiped under us).
  return $db->setting('auth.cookie_secret') // $hex;
}

1;
