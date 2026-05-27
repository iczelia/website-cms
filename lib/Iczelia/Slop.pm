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

package Iczelia::Slop;
use strict;
use warnings;
use Fcntl    qw(:DEFAULT :flock);
use Encode   ();
use JSON::PP ();
use Iczelia::Slop::Tokenizer ();

# Iczelia::Slop::Model is required lazily from ensure_loaded() so that
# a missing or broken Inline::C build only disables the slop trap
# instead of taking down the whole daemon.

# AI-slop bot trap. Targets a small set of crawlers that hit at high
# rates; for everyone else this module is invisible. Cached per-path
# in the slop_pages table so the second hit on the same URL serves
# instantly. Generation is serialized via flock so we never have all
# workers stuck running the model at once.

my @TARGETS = (
  qr{\bdotbot\b}i,                                 # SEO crawler
  qr{meta-externalagent|meta-externalfetcher}i,    # Meta's AI scrapers
);

# How long a generated page stays cached before the next hit triggers
# a fresh generation.
our $TTL_S = 300;

sub new {
  my ($class, %arg) = @_;
  my $self = bless {
    db        => $arg{db},
    cfg       => $arg{cfg},
    share_dir => $arg{cfg}{'share-dir'},
    tmp_dir   => $arg{cfg}{'tmp-dir'},
    model     => undef,
    tokenizer => undef,
    loaded    => 0,
  }, $class;
  return $self;
}

# Load model + tokenizer once.
sub ensure_loaded {
  my ($self) = @_;
  return $self->{loaded} if $self->{loaded};
  my $dir = "$self->{share_dir}/tinyllm";
  return 0 unless -r "$dir/manifest.json" && -r "$dir/weights.bin";

  # Defer requiring Slop::Model.
  my $captured = '';
  my $ok = do {
    local *STDERR;
    open STDERR, '>', \$captured;
    my $r = eval {require Iczelia::Slop::Model; 1};
    $r;
  };
  if (!$ok) {
    warn "slop: Iczelia::Slop::Model unavailable; trap will serve stubs\n";
    return 0;
  }

  my $json;
  open my $fh, '<:raw', "$dir/manifest.json" or return 0;
  {local $/; $json = <$fh>}
  close $fh;
  # utf8(1): see Iczelia::Slop::Model::load, the manifest contains
  # multi-byte SentencePiece pieces that must round-trip as characters.
  my $mf = eval {JSON::PP->new->utf8(1)->decode($json)} or return 0;

  $self->{tokenizer} = Iczelia::Slop::Tokenizer->new(tokenizer => $mf->{tokenizer});
  $self->{model}     = eval {Iczelia::Slop::Model->load($dir)};
  if (!$self->{model}) {
    warn "slop: model load failed: $@" if $@;
    return 0;
  }
  $self->{loaded} = 1;
  return 1;
}

sub is_target_ua {
  my ($ua) = @_;
  return 0 unless defined $ua && length $ua;
  for my $re (@TARGETS) {return 1 if $ua =~ $re}
  return 0;
}

# Entry point called from the pre_dispatch hook. Returns an HTTP
# response hashref to short-circuit dispatch, or undef to let normal
# routing run.
sub maybe_serve {
  my ($self, $req) = @_;
  return undef unless $req && ref($req) eq 'HASH';
  return undef unless ($req->{method} || 'GET') eq 'GET';

  my $ua = $req->{headers}{'user-agent'};
  return undef unless is_target_ua($ua);

  my $path = $req->{path} // '/';
  $path = '/' unless length $path;

  return $self->_serve_for($path);
}

sub _serve_for {
  my ($self, $path) = @_;

  my $body = eval {$self->_cache_get($path)};
  return _resp($body) if defined $body && length $body;

  # Generation lock keeps every worker in the prefork pool from running
  # the model in parallel. Only one slop generation runs at a time;
  # losers serve a stub so they can answer the next request quickly.
  my $lock_path = ($self->{tmp_dir} || '/tmp') . '/slop.lock';
  my $lf;
  if (!open $lf, '>>', $lock_path) {
    return _resp(_stub_html($path));
  }
  if (!flock($lf, LOCK_EX | LOCK_NB)) {
    close $lf;
    return _resp(_stub_html($path));
  }

  # Re-check after acquiring the lock; another worker may have just
  # finished generating this exact path.
  $body = eval {$self->_cache_get($path)};
  if (defined $body && length $body) {
    flock($lf, LOCK_UN);
    close $lf;
    return _resp($body);
  }

  # Sweep expired rows while we hold the lock. This is the only place
  # we ever delete, so the table stays bounded as long as bots keep
  # generating new misses.
  eval {$self->_gc_expired};

  if (!$self->ensure_loaded) {
    flock($lf, LOCK_UN);
    close $lf;
    return _resp(_stub_html($path));
  }

  $body = eval {$self->_generate_html($path)};
  if (!defined $body || !length $body) {
    flock($lf, LOCK_UN);
    close $lf;
    return _resp(_stub_html($path));
  }

  eval {$self->_cache_put($path, $body)};

  flock($lf, LOCK_UN);
  close $lf;
  return _resp($body);
}

sub _resp {
  my ($body) = @_;

  # No X-Robots-Tag / noindex: we want trapped crawlers to ingest and
  # follow links into more slop. Cache-Control: no-store keeps the
  # response out of the shared response_cache table (real users have
  # different UAs and must see real content).
  return {
    status    => 200,
    headers   => {
      'Content-Type'           => 'text/html; charset=utf-8',
      'Cache-Control'          => 'no-store',
      'X-Content-Type-Options' => 'nosniff',
    },
    body      => $body,
    _no_cache => 1,
  };
}

sub _cache_get {
  my ($self, $path) = @_;
  return undef unless $self->{db};
  my $row = $self->{db}->row(
    'SELECT body FROM slop_pages WHERE path = ? AND created_at > ?',
    $path, time - $TTL_S
  );
  return $row ? $row->{body} : undef;
}

sub _cache_put {
  my ($self, $path, $body) = @_;
  return unless $self->{db};
  $self->{db}->do_(
    'INSERT OR REPLACE INTO slop_pages (path, body, created_at)
       VALUES (?, ?, ?)', $path, $body, time
  );
}

# Sweep expired rows. Cheap (an indexed range delete) and only called
# from inside the generation lock, so at most one sweep is in flight
# per slop-burst across the whole worker pool.
sub _gc_expired {
  my ($self) = @_;
  return unless $self->{db};
  $self->{db}
    ->do_('DELETE FROM slop_pages WHERE created_at <= ?', time - $TTL_S);
}

# Compose the prompt from the URL, generate up to MAX_NEW tokens, and
# wrap the result in plausible-looking HTML with tarpit links pointing
# at sibling paths under the same site.
sub _generate_html {
  my ($self, $path) = @_;

  my $title  = _title_from_path($path);
  my $prompt = "$title.\n\nOnce upon a time,";

  my $ids = $self->{tokenizer}->encode($prompt);

  my $buffer = '';
  my $bytes  = '';
  my $bos    = $self->{tokenizer}->bos_id;
  my $eos    = $self->{tokenizer}->eos_id;
  my $hard_cap = 220;

  my $token_cb = sub {
    my ($id) = @_;
    my ($kind, $val) = $self->{tokenizer}->decode_one($id);
    if ($kind eq 'byte')    {$bytes  .= $val}
    elsif ($kind eq 'text') {
      if (length $bytes) {
        $buffer .= Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT());
        $bytes = '';
      }
      $buffer .= $val;
    }
    return length($buffer) > 2000;    # safety cap on raw text
  };

  $self->{model}->generate(
    $ids,
    max_new     => $hard_cap,
    temperature => 0.9,
    top_k       => 50,
    eos_id      => $eos,
    on_token    => $token_cb,
  );
  if (length $bytes) {
    $buffer .= Encode::decode('UTF-8', $bytes, Encode::FB_DEFAULT());
  }

  # Strip the prompt prefix from the generated stream by trimming the
  # original "Once upon a time," from the front of the decoded buffer.
  $buffer =~ s/\A\s*\Q$title\E\.?\s*//;

  return _render_html($title, $buffer, $path);
}

sub _title_from_path {
  my ($path) = @_;
  my $slug = $path;
  $slug =~ s{/+\z}{};
  $slug =~ s{^/+}{};
  $slug =~ s{\?.*\z}{}s;
  $slug =~ s{#.*\z}{}s;
  $slug = (split m{/}, $slug)[-1] // '';
  $slug =~ tr{_+}{ };
  $slug =~ s{-}{ }g;
  $slug =~ s{[^A-Za-z0-9 ]+}{}g;
  $slug =~ s{\s+}{ }g;
  $slug =~ s{^\s+|\s+$}{}g;
  return 'Notes' unless length $slug;

  # Title-case: capitalise the first letter of each word.
  $slug =~ s/\b([a-z])/uc $1/ge;
  return $slug;
}

# Take a flat blob of model output and split it on sentence ends to
# build <p> paragraphs; group ~3 sentences per paragraph.
sub _paragraphs {
  my ($text) = @_;
  $text =~ s/\s+/ /g;
  $text =~ s/^\s+|\s+$//g;
  return ('Notes on this topic.') unless length $text;
  my @sents = $text =~ /([^.!?]+[.!?]+)/g;
  if (!@sents) {push @sents, $text}
  my @paras;
  while (@sents) {
    my @chunk = splice @sents, 0, 3;
    my $p = join(' ', @chunk);
    $p =~ s/^\s+|\s+$//g;
    push @paras, $p if length $p;
  }
  return @paras;
}

# Compose ~5 tarpit links that lead deeper into the slop. The point is
# to keep the bot crawling fresh URLs forever; each generated page
# gets its own slop entry on demand.
sub _tarpit_links {
  my ($path, $text) = @_;
  my @words = grep {length($_) >= 4 && /^[a-z]+\z/i} split /\s+/, lc $text;
  my %seen;
  @words = grep {!$seen{$_}++} @words;
  @words = @words[0 .. 19] if @words > 20;

  my @prefixes = ('/blog/', '/journal/', '/notes/', '/tag/', '/archive/');
  my @links;
  for my $i (0 .. 4) {
    last if !@words;
    my $w1 = splice @words, int(rand @words), 1;
    my $w2 = @words ? splice(@words, int(rand @words), 1) : '';
    my $prefix = $prefixes[$i % @prefixes];
    my $slug   = $w2 ? "$w1-$w2" : $w1;
    push @links, {
      href => "$prefix$slug",
      text => ucfirst($w1) . ($w2 ? " and $w2" : ''),
    };
  }
  return @links;
}

sub _escape_html {
  my ($s) = @_;
  $s = '' unless defined $s;
  $s =~ s/&/&amp;/g;
  $s =~ s/</&lt;/g;
  $s =~ s/>/&gt;/g;
  $s =~ s/"/&quot;/g;
  return $s;
}

sub _render_html {
  my ($title, $body_text, $path) = @_;
  my @paras = _paragraphs($body_text);
  my @links = _tarpit_links($path, $body_text);

  my $t = _escape_html($title);
  my $html = <<"HEAD";
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$t</title>
<meta name="description" content="$t">
<style>
body{max-width:62ch;margin:2.5em auto;padding:0 1em;font:16px/1.55 Georgia,serif;color:#222}
h1{font-size:1.6em;margin:0 0 .6em}
p{margin:1em 0}
nav{margin-top:2.5em;padding-top:1em;border-top:1px solid #ccc;font-size:.95em}
nav h2{font-size:1em;margin:0 0 .4em;color:#666;font-weight:normal}
nav ul{margin:0;padding-left:1.2em}
</style>
</head>
<body>
<article>
<h1>$t</h1>
HEAD

  for my $p (@paras) {
    $html .= '<p>' . _escape_html($p) . "</p>\n";
  }
  $html .= "</article>\n";

  if (@links) {
    $html .= "<nav><h2>Related</h2><ul>\n";
    for my $l (@links) {
      my $h = _escape_html($l->{href});
      my $x = _escape_html($l->{text});
      $html .= qq{<li><a href="$h">$x</a></li>\n};
    }
    $html .= "</ul></nav>\n";
  }
  $html .= "</body></html>\n";
  return $html;
}

# Placeholder served when generation is locked by another worker or
# the model isn't installed.
sub _stub_html {
  my ($path) = @_;
  my $t = _escape_html(_title_from_path($path));
  return <<"HTML";
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><title>$t</title>
</head><body>
<h1>$t</h1>
<p>This page is being prepared.</p>
</body></html>
HTML
}

1;
