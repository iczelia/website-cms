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

package Iczelia::Cache;
use strict;
use warnings;
use Carp              qw(croak);
use DBI               ();
use Digest::SHA       qw(sha256_hex);
use Encode            ();
use POSIX             ();
use Iczelia::Minify   ();
use Iczelia::Compress ();

# Response cache for public GETs. The request path stores the body
# raw; compress_pending() fills gz/br variants from the warmer.

sub new {
  my ($class, %arg) = @_;
  croak "db required" unless $arg{db};
  return bless {
    db       => $arg{db},
    brotli_q => $arg{brotli_q} // 11,
    zopfli_i => $arg{zopfli_i} // 15,

    # Below this, the gzip header outweighs the saving.
    min_size => $arg{min_size} // 256,
    compress => exists $arg{compress} ? $arg{compress} : 1,
  }, $class;
}

my %PUBLISH_BUST_PATHS =
  map {$_ => 1} qw(/ /blog/ /journal/ /feed.xml /index.xml /rss.xml);

# Daemon-cache eligibility. Returns 1 to skip both get() and put() for
# this request. Per-response opt-outs live on the response itself (the
# `_no_cache` flag honoured in Server::_handle_one); the patterns here
# are structural bypasses for paths whose contents always vary per
# request and so don't even warrant a cache lookup.
sub bypass_for_request {
  my ($self, $req) = @_;
  return 1 unless $req->{method} eq 'GET' || $req->{method} eq 'HEAD';
  return 1 if length($req->{query} // '');
  my $path = $req->{path};
  return 1 unless defined $path && length $path;

  # Authenticated admin: never cache.
  return 1 if $path =~ m{^/admin/?};
  return 1 if $path =~ m{^/login/?$};
  return 1 if $path =~ m{^/logout/?$};

  # Home embeds a live GMT clock; caching would freeze it.
  return 1 if $path eq '/';

  # Guestbook embeds a per-visitor anon-CSRF token bound to a cookie;
  # caching would leak one user's token to everyone else.
  return 1 if $path =~ m{^/guestbook/?$};
  return 1 if $req->{cookies} && exists $req->{cookies}{iczelia_sid};

  # Chrome image packs dispatch avif/png by Accept and emit Vary: Accept.
  # The internal cache keys by path alone and stamps a fixed Vary, so
  # leave it to nginx (which honours Vary) to split these.
  return 1
    if $path =~ m{^/assets-(?:1024x768|800x600|600x400|about)/};
  return 0;
}

# Response-side: Cache-Control max-age stamped on cache hits for static
# assets. Distinct from bypass_for_request, which decides whether to
# look up at all.
sub _cache_control_for {
  my ($path) = @_;
  return 'public, max-age=31536000, immutable'
    if $path =~ m{^/(?:vendor/|fonts/|assets-)};
  return 'public, max-age=86400'
    if $path =~ m{^/(?:media/|favicon\.ico\z)};
  return 'public, max-age=3600'
    if $path =~ m{^/(?:cms\.(?:css|js)|style\.|about\.compat\.css|common\.compat\.css)};
  return 'public, max-age=600' if $path eq '/pub.pgp';
  return 'no-store';
}

# Rows whose content-type is already-compressed media (image, font,
# pre-zipped). Stored as body but never gz/br'd.
sub _is_binary_media {
  my ($ct) = @_;
  return 0 unless defined $ct;
  return 1 if $ct =~ m{^(?:image|audio|video|font)/}i;
  return 1
    if $ct =~
    m{^application/(?:zip|gzip|x-tar|x-bzip|octet-stream|font-woff|x-protobuf|pdf)\b}i;
  return 0;
}

# Cache miss when a post's publish_at just crossed and listings are
# stale. tx_immediate serializes concurrent workers; per-worker
# memoization skips the SELECT until the next future boundary.
sub _check_publish_boundary {
  my ($self, $path) = @_;
  return 0 unless $PUBLISH_BUST_PATHS{$path};
  my $now = time;
  return 0
    if defined $self->{_next_publish_at}
    && $now < $self->{_next_publish_at};

  my $crossed = 0;
  my $next_at;
  my $ok = eval {
    $self->{db}->tx_immediate(
      sub {
        my $d   = shift;
        my $row = $d->row(
          q{SELECT MIN(publish_at) AS next_at,
                         SUM(CASE WHEN publish_at <= strftime('%s','now')
                                  AND (rendered_at IS NULL
                                       OR rendered_at < publish_at)
                                  THEN 1 ELSE 0 END) AS crossed
                    FROM posts
                   WHERE publish_at IS NOT NULL AND draft=0
                     AND (rendered_at IS NULL OR rendered_at < publish_at)}
        );
        $next_at = $row && defined $row->{next_at} ? $row->{next_at} : undef;
        $crossed = $row && $row->{crossed}         ? $row->{crossed} : 0;
        return unless $crossed;

        # Stamp inside the tx so a sibling worker skips the bust.
        $d->do_(
          q{UPDATE posts SET rendered_at = publish_at + 1
                   WHERE publish_at IS NOT NULL AND draft=0
                     AND publish_at <= strftime('%s','now')
                     AND (rendered_at IS NULL OR rendered_at < publish_at)}
        );
      }
    );
    1;
  };
  if (!$ok || !$crossed) {
    $self->{_next_publish_at} = defined $next_at ? $next_at : $now + 3600;
    return 0;
  }

  # Bust outside the tx to release the write lock first.
  $self->bust('/');
  $self->bust_prefix('/blog/');
  $self->bust_prefix('/journal/');
  $self->bust_many(qw(/feed.xml /index.xml /rss.xml));
  delete $self->{_next_publish_at};
  return 1;
}

sub get {
  my ($self, $path, $req) = @_;
  return undef unless defined $path && length $path;
  return undef if $self->_check_publish_boundary($path);

  # Header-only fetch: lengths over BLOBs are O(1) in SQLite, so the
  # decision-making query stays cheap. We pull only the body column we
  # actually need in the second query.
  my $head = $self->{db}->row(
    'SELECT status, content_type, etag,
                length(body)    AS len_body,
                length(body_gz) AS len_gz,
                length(body_br) AS len_br
           FROM response_cache WHERE path=?', $path
  );
  return undef unless $head;

  my $etag = $head->{etag};

  # If-None-Match match -> 304 so clients keep their cached body.
  my $inm = $req && $req->{headers}{'if-none-match'};
  if (defined $inm && length $inm) {
    for my $tag (split /\s*,\s*/, $inm) {
      $tag =~ s/^\s+//;
      $tag =~ s/\s+$//;
      $tag =~ s/^W\///i;
      $tag =~ s/^"|"$//g;
      if ($tag eq $etag) {
        return {
          status  => 304,
          headers => {
            ETag => qq{"$etag"},
            Vary => 'Accept-Encoding',
          },
          body => '',
        };
      }
    }
  }

  my $accept = '';
  if ($req && $req->{headers}) {
    $accept = $req->{headers}{'accept-encoding'} // '';
  }
  my ($col, $enc);
  if ($accept =~ /\bbr\b/ && ($head->{len_br} // 0) > 0) {
    $col = 'body_br';
    $enc = 'br';
  }
  elsif ($accept =~ /\bgzip\b/ && ($head->{len_gz} // 0) > 0) {
    $col = 'body_gz';
    $enc = 'gzip';
  }
  else {
    $col = 'body';
  }

  my $body =
    $self->{db}->one("SELECT $col FROM response_cache WHERE path=?", $path);
  return undef unless defined $body;

  my %hdr = (
    'Content-Type'  => $head->{content_type},
    ETag            => qq{"$etag"},
    Vary            => 'Accept-Encoding',
    'Cache-Control' => _cache_control_for($path),
    'X-Cache'       => 'HIT',
  );
  $hdr{'Content-Encoding'} = $enc if $enc;

  return {
    status  => $head->{status},
    headers => \%hdr,
    body    => $body,
  };
}

# Returns the canonical (etag/Vary-stamped) response on store, or
# undef if uncacheable. Lets the caller skip a follow-up get() that
# would just re-fetch what we already have in hand.
sub put {
  my ($self, $path, $resp) = @_;
  return undef unless defined $path && length $path;
  return undef unless defined $resp;
  my $st = $resp->{status} // 200;
  return undef unless $st == 200;
  return undef if $resp->{cookies} && @{$resp->{cookies}};

  my $body = $resp->{body};
  return undef unless defined $body && length $body;
  if (Encode::is_utf8($body)) {
    $body = Encode::encode('UTF-8', $body);
  }

  my $hdrs = $resp->{headers} || {};
  my $cc   = lc($hdrs->{'Cache-Control'} // '');
  return undef if $cc =~ /\b(?:private|no-store|no-cache)\b/;

  # Catch handlers that bypassed $resp->{cookies} via raw headers.
  for my $k (keys %$hdrs) {
    return undef if lc($k) eq 'set-cookie';
  }

  my $ct = $hdrs->{'Content-Type'} // 'text/html; charset=utf-8';

  # Binary media (PNG, fonts, etc.) skip the gz/br pass but still get
  # stored as body so subsequent hits avoid the disk read. Stamp
  # gz/br as '' upfront so compress_pending doesn't keep rescanning.
  my $is_bin = _is_binary_media($ct);

  if (!$is_bin) {

    # Minify before compression: brotli can't otherwise dedupe runs.
    if ($ct =~ m{^text/html\b}i) {
      $body = Iczelia::Minify::html($body);
    }
    elsif ($ct =~ m{^text/css\b}i) {
      $body = Iczelia::Minify::css($body);
    }
  }

  my $etag = sha256_hex($body);

  # SQL_BLOB matters: sqlite_unicode would re-encode strings and
  # corrupt the gzip/brotli payloads.
  my $stored = eval {
    my $sth = $self->{db}->dbh->prepare(
      q{INSERT INTO response_cache(path,status,content_type,body,body_gz,body_br,etag,created_at)
              VALUES(?,?,?,?,?,?,?, strftime('%s','now'))
              ON CONFLICT(path) DO UPDATE SET
                  status=excluded.status, content_type=excluded.content_type,
                  body=excluded.body, body_gz=excluded.body_gz,
                  body_br=excluded.body_br, etag=excluded.etag,
                  created_at=excluded.created_at}
    );
    $sth->bind_param(1, $path);
    $sth->bind_param(2, $st);
    $sth->bind_param(3, $ct);
    $sth->bind_param(4, $body, DBI::SQL_BLOB());
    if ($is_bin) {
      $sth->bind_param(5, '', DBI::SQL_BLOB());
      $sth->bind_param(6, '', DBI::SQL_BLOB());
    }
    else {
      $sth->bind_param(5, undef);
      $sth->bind_param(6, undef);
    }
    $sth->bind_param(7, $etag);
    $sth->execute;
    1;
  };

  # Storage failure (SQLITE_BUSY etc.) shouldn't 500 the request.
  return undef unless $stored;

  return {
    status  => $st,
    headers => {
      'Content-Type'  => $ct,
      ETag            => qq{"$etag"},
      Vary            => 'Accept-Encoding',
      'Cache-Control' => _cache_control_for($path),
      'X-Cache'       => 'STORE',
    },
    body => $body,
  };
}

# Fill body_gz/body_br for rows missing them. Returns rows updated.
# Statement is prepared once and the batch runs in one tx so we pay
# one fsync regardless of how many rows compress this pass.
sub compress_pending {
  my ($self, %opt) = @_;
  return 0 unless $self->{compress};
  my $limit = $opt{limit} || 50;

  my $rows = $self->{db}->all(
    q{SELECT path, content_type, body
            FROM response_cache
           WHERE (body_gz IS NULL OR body_br IS NULL)
             AND body IS NOT NULL
           ORDER BY created_at DESC
           LIMIT ?}, $limit
  );
  return 0 unless @$rows;

  my $sth = $self->{db}->dbh->prepare(
    q{UPDATE response_cache SET body_gz=?, body_br=? WHERE path=?});

  my $count = 0;
  $self->{db}->tx(
    sub {
      for my $row (@$rows) {
        my $body = $row->{body};
        my $ct   = $row->{content_type} // '';
        my $skip =
            !defined $body
          || length($body) < $self->{min_size}
          || _is_binary_media($ct);

        if ($skip) {

          # Stamp ''/'' so this row drops out of the
          # NULL-gz/NULL-br scan instead of starving real work.
          $sth->bind_param(1, '', DBI::SQL_BLOB());
          $sth->bind_param(2, '', DBI::SQL_BLOB());
          $sth->bind_param(3, $row->{path});
          $sth->execute;
          $count++;
          next;
        }

        my $body_gz = $self->_gzip($body);
        my $body_br = $self->_brotli($body);

        # Both compressors failed: leave NULL so the next pass
        # retries rather than poisoning the row with empty BLOBs.
        next unless defined $body_gz || defined $body_br;
        $body_gz = '' unless defined $body_gz;
        $body_br = '' unless defined $body_br;

        $sth->bind_param(1, $body_gz, DBI::SQL_BLOB());
        $sth->bind_param(2, $body_br, DBI::SQL_BLOB());
        $sth->bind_param(3, $row->{path});
        $sth->execute;
        $count++;
      }
    }
  );
  return $count;
}

sub bust {
  my ($self, $path) = @_;
  return unless defined $path && length $path;
  $self->{db}->do_('DELETE FROM response_cache WHERE path=?', $path);
}

sub bust_many {
  my ($self, @paths) = @_;
  return unless @paths;
  my $db = $self->{db};
  $db->tx(
    sub {
      for my $p (@paths) {
        next unless defined $p && length $p;
        $db->do_('DELETE FROM response_cache WHERE path=?', $p);
      }
    }
  );
}

sub bust_prefix {
  my ($self, $prefix) = @_;
  return unless defined $prefix && length $prefix;
  my $like = $prefix;
  $like =~ s/([%_\\])/\\$1/g;
  $self->{db}->do_("DELETE FROM response_cache WHERE path LIKE ? ESCAPE '\\'",
    "$like%");
}

sub bust_all {
  my ($self) = @_;
  $self->{db}->do_('DELETE FROM response_cache');
}

sub size {
  my ($self) = @_;
  return $self->{db}->one('SELECT COUNT(*) FROM response_cache') // 0;
}

sub _gzip {
  my ($self, $body) = @_;
  return Iczelia::Compress::gzip($body, iterations => $self->{zopfli_i});
}

sub _brotli {
  my ($self, $body) = @_;
  return Iczelia::Compress::brotli($body, $self->{brotli_q});
}

1;
