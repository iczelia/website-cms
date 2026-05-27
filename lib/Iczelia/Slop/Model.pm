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

package Iczelia::Slop::Model;
use strict;
use warnings;
use JSON::PP       ();
use File::Basename ();
use File::Spec     ();
use Cwd            ();
use Carp           qw(croak);

# C-accelerated Llama-style transformer inference for arnir0/Tiny-LLM.
# 1-layer, hidden=192, intermediate=1024, n_heads=2, n_kv_heads=1
# (GQA 2:1), head_dim=96, RoPE theta=10000, RMSNorm, SwiGLU.

# Inline cache directory.
my $inline_dir;

BEGIN {
  if ($ENV{ICZELIA_INLINE_DIR}) {
    $inline_dir = $ENV{ICZELIA_INLINE_DIR};
  }
  else {
    my $here = Cwd::abs_path(__FILE__);
    my $dir  = File::Basename::dirname($here);             # .../Slop
    for (1 .. 3) {$dir = File::Basename::dirname($dir)}    # project root
    $inline_dir = "$dir/_Inline";
  }
  unless (-d $inline_dir) {
    require File::Path;
    File::Path::make_path($inline_dir);
  }
}

# Slurp the C source out of __DATA__ at compile time so it works
# whether the module is `use`d or `require`d.
my $C_SRC;
BEGIN {
  my $here = __FILE__;
  open my $fh, '<:raw', $here or die "open $here: $!";
  local $/;
  my $whole = <$fh>;
  close $fh;
  ($C_SRC) = $whole =~ /^__C__\s*\n(.*)\z/ms;
  die "no __C__ section in $here" unless defined $C_SRC;
}

# CCFLAGSEX hook lets dev environments missing libcrypt-dev point at a
# locally-extracted copy of crypt.h. Production images ship libcrypt-dev
# in the build stage so the var is unset there.
use Inline (
  C        => $C_SRC,
  NAME     => 'Iczelia::Slop::Model',
  DIRECTORY => $inline_dir,
  OPTIMIZE => '-O3 -fno-strict-aliasing',
  ($ENV{ICZELIA_INLINE_CCFLAGS}
    ? (CCFLAGSEX => $ENV{ICZELIA_INLINE_CCFLAGS}) : ()),
);

sub load {
  my ($class, $dir) = @_;
  croak "model dir required" unless defined $dir && length $dir;
  my $mf = "$dir/manifest.json";
  my $wf = "$dir/weights.bin";
  -r $mf or croak "missing $mf (run bin/iczelia-tinyllm-convert)";
  -r $wf or croak "missing $wf (run bin/iczelia-tinyllm-convert)";

  open my $jf, '<:raw', $mf or croak "open $mf: $!";
  local $/;
  my $manifest_json = <$jf>;
  close $jf;

  # utf8(1): the manifest carries U+2581 (SentencePiece's word-boundary
  # marker) and other non-ASCII pieces in the vocab.
  my $manifest = JSON::PP->new->utf8(1)->decode($manifest_json);
  my $cfg      = $manifest->{config};

  open my $bf, '<:raw', $wf or croak "open $wf: $!";
  my $sz = -s $bf;
  my $blob;
  read $bf, $blob, $sz;
  close $bf;
  croak "short read: $sz vs got " . length($blob) unless length($blob) == $sz;

  my %tensor;
  for my $t (@{$manifest->{tensors}}) {
    $tensor{$t->{name}} = $t;
  }
  my $offset = sub {
    my $name = shift;
    my $t = $tensor{$name} or croak "missing tensor $name";
    return $t->{offset};
  };

  # Hand the weight blob + per-tensor offsets (in fp32 elements) to the
  # C side. slop_init() retains a reference on the blob SV so the
  # underlying bytes stay alive for the lifetime of the process.
  slop_init(
    $blob,
    $cfg->{hidden_size}            + 0,
    $cfg->{intermediate_size}      + 0,
    $cfg->{num_attention_heads}    + 0,
    $cfg->{num_key_value_heads}    + 0,
    $cfg->{vocab_size}             + 0,
    $cfg->{max_position_embeddings} + 0,
    $cfg->{rms_norm_eps}           + 0.0,
    ($cfg->{rope_theta} // 10000.0) + 0.0,
    $offset->('model.embed_tokens.weight'),
    $offset->('model.layers.0.input_layernorm.weight'),
    $offset->('model.layers.0.self_attn.q_proj.weight'),
    $offset->('model.layers.0.self_attn.k_proj.weight'),
    $offset->('model.layers.0.self_attn.v_proj.weight'),
    $offset->('model.layers.0.self_attn.o_proj.weight'),
    $offset->('model.layers.0.post_attention_layernorm.weight'),
    $offset->('model.layers.0.mlp.gate_proj.weight'),
    $offset->('model.layers.0.mlp.up_proj.weight'),
    $offset->('model.layers.0.mlp.down_proj.weight'),
    $offset->('model.norm.weight'),
    $offset->('lm_head.weight'),
  );

  return bless {
    cfg     => $cfg,
    max_pos => $cfg->{max_position_embeddings},
  }, $class;
}

# Generate up to $max_new tokens after $prompt_ids. $cb->($token_id)
# is called for each generated token; return-true from the callback
# stops generation early. Returns the count of tokens generated.
sub generate {
  my ($self, $prompt_ids, %opt) = @_;
  my $max_new = $opt{max_new} || 128;
  my $temp    = exists $opt{temperature} ? $opt{temperature} + 0.0 : 1.0;
  my $top_k   = exists $opt{top_k}       ? $opt{top_k} + 0         : 40;
  my $eos     = $opt{eos_id} // $self->{cfg}{eos_token_id} // 2;
  my $cb      = $opt{on_token};
  my $rng     = $opt{rand};

  slop_reset();

  # Feed every prompt token through forward(). The last call returns a
  # token (the model's pick for "what comes next") which becomes our
  # first generated token. Drop it on the floor for prompts -- the
  # tokens we want to keep start with the first sample after the prompt.
  my $next;
  for my $id (@$prompt_ids) {
    $next = slop_forward_sample($id, $temp, $top_k, $rng ? $rng->() : rand());
  }

  my $n = 0;
  my $pos = scalar @$prompt_ids;
  for (1 .. $max_new) {
    last if !defined $next || $next == $eos;
    $n++;
    last if $cb && $cb->($next);
    last if $pos >= $self->{max_pos};
    $next = slop_forward_sample($next, $temp, $top_k, $rng ? $rng->() : rand());
    $pos++;
  }
  return $n;
}

1;

__DATA__
__C__
#include <math.h>
#include <stdlib.h>
#include <string.h>
#if defined(__GNUC__) || defined(__clang__)
#include <alloca.h>
#endif

/* Static model state. Module-global because Slop loads exactly one
 * model into the supervisor and forked workers inherit it via COW.
 * Multi-model use is out of scope. */
static int H_   = 0;   /* hidden_size */
static int II_  = 0;   /* intermediate_size */
static int NH_  = 0;   /* num_attention_heads */
static int NK_  = 0;   /* num_kv_heads */
static int D_   = 0;   /* head_dim = H / NH */
static int V_   = 0;   /* vocab_size */
static int KV_  = 0;   /* NK * D, combined K/V width */
static int GRP_ = 0;   /* NH / NK, heads per KV head */
static int MAX_POS_ = 0;
static float RMS_EPS_ = 1e-5f;
static float ROPE_TH_ = 10000.0f;
static float INV_SD_  = 0.0f;

/* Weight pointers into the model.embed_tokens et al. SV bytes. */
static const float *W_EMBED, *W_LN1, *W_Q, *W_K, *W_V, *W_O;
static const float *W_LN2, *W_GATE, *W_UP, *W_DOWN, *W_LNF, *W_LMHEAD;

/* Keep a strong ref to the weights SV so it isn't freed under us. */
static SV *WEIGHTS_KEEP = NULL;

/* Per-forward scratch (heap-allocated; reused across calls). */
static float *KCACHE = NULL;   /* [MAX_POS][KV] */
static float *VCACHE = NULL;   /* [MAX_POS][KV] */
static float *ROPE_COS = NULL; /* [MAX_POS][D/2] */
static float *ROPE_SIN = NULL;
static float *XBUF, *FBUF, *QBUF, *KBUF, *VBUF, *CTXBUF, *OBUF;
static float *GBUF, *UBUF, *DBUF, *LOGITS, *SCORES;
static int POS_ = 0;

static void rmsnorm(float *out, const float *in, const float *gain, int n, float eps) {
    double ss = 0.0;
    int i;
    for (i = 0; i < n; i++) ss += (double)in[i] * (double)in[i];
    double rs = 1.0 / sqrt(ss / (double)n + (double)eps);
    for (i = 0; i < n; i++) out[i] = (float)((double)in[i] * rs * (double)gain[i]);
}

static void matvec(float *out, const float *W, const float *x, int out_dim, int in_dim) {
    int i, j;
    for (i = 0; i < out_dim; i++) {
        const float *r = W + (size_t)i * (size_t)in_dim;
        float s = 0.0f;
        for (j = 0; j < in_dim; j++) s += r[j] * x[j];
        out[i] = s;
    }
}

static void apply_rope(float *vec, int n_heads, int p) {
    int half = D_ / 2;
    const float *cs = ROPE_COS + (size_t)p * half;
    const float *sn = ROPE_SIN + (size_t)p * half;
    int h, i;
    for (h = 0; h < n_heads; h++) {
        float *v = vec + h * D_;
        for (i = 0; i < half; i++) {
            float lo = v[i];
            float hi = v[i + half];
            float c = cs[i], s = sn[i];
            v[i]        = lo * c - hi * s;
            v[i + half] = hi * c + lo * s;
        }
    }
}

void slop_init(SV *weights_sv,
               int hidden, int intermediate, int n_heads, int n_kv_heads,
               int vocab, int max_position,
               double rms_eps_in, double rope_theta_in,
               IV embed_off, IV ln1_off, IV q_off, IV k_off, IV v_off, IV o_off,
               IV ln2_off, IV gate_off, IV up_off, IV down_off, IV lnf_off,
               IV lmhead_off) {
    H_   = hidden;
    II_  = intermediate;
    NH_  = n_heads;
    NK_  = n_kv_heads;
    D_   = H_ / NH_;
    V_   = vocab;
    KV_  = NK_ * D_;
    GRP_ = NH_ / NK_;
    MAX_POS_ = max_position;
    RMS_EPS_ = (float)rms_eps_in;
    ROPE_TH_ = (float)rope_theta_in;
    INV_SD_  = 1.0f / sqrtf((float)D_);

    /* Pin the weights SV so its buffer stays valid for the process. */
    if (WEIGHTS_KEEP) SvREFCNT_dec(WEIGHTS_KEEP);
    WEIGHTS_KEEP = newSVsv(weights_sv);

    STRLEN wlen;
    const float *base = (const float *)SvPVbyte(WEIGHTS_KEEP, wlen);
    W_EMBED  = base + embed_off;
    W_LN1    = base + ln1_off;
    W_Q      = base + q_off;
    W_K      = base + k_off;
    W_V      = base + v_off;
    W_O      = base + o_off;
    W_LN2    = base + ln2_off;
    W_GATE   = base + gate_off;
    W_UP     = base + up_off;
    W_DOWN   = base + down_off;
    W_LNF    = base + lnf_off;
    W_LMHEAD = base + lmhead_off;

    free(KCACHE);
    free(VCACHE);
    KCACHE = (float *)calloc((size_t)MAX_POS_ * KV_, sizeof(float));
    VCACHE = (float *)calloc((size_t)MAX_POS_ * KV_, sizeof(float));

    free(ROPE_COS);
    free(ROPE_SIN);
    int half = D_ / 2;
    ROPE_COS = (float *)malloc((size_t)MAX_POS_ * half * sizeof(float));
    ROPE_SIN = (float *)malloc((size_t)MAX_POS_ * half * sizeof(float));
    {
        int p, i;
        for (p = 0; p < MAX_POS_; p++) {
            for (i = 0; i < half; i++) {
                double freq  = 1.0 / pow((double)ROPE_TH_, (double)(2 * i) / (double)D_);
                double angle = (double)p * freq;
                ROPE_COS[p * half + i] = (float)cos(angle);
                ROPE_SIN[p * half + i] = (float)sin(angle);
            }
        }
    }

    free(XBUF);   XBUF   = (float *)malloc(H_  * sizeof(float));
    free(FBUF);   FBUF   = (float *)malloc(H_  * sizeof(float));
    free(QBUF);   QBUF   = (float *)malloc(H_  * sizeof(float));
    free(KBUF);   KBUF   = (float *)malloc(KV_ * sizeof(float));
    free(VBUF);   VBUF   = (float *)malloc(KV_ * sizeof(float));
    free(CTXBUF); CTXBUF = (float *)malloc(H_  * sizeof(float));
    free(OBUF);   OBUF   = (float *)malloc(H_  * sizeof(float));
    free(GBUF);   GBUF   = (float *)malloc(II_ * sizeof(float));
    free(UBUF);   UBUF   = (float *)malloc(II_ * sizeof(float));
    free(DBUF);   DBUF   = (float *)malloc(H_  * sizeof(float));
    free(LOGITS); LOGITS = (float *)malloc(V_  * sizeof(float));
    free(SCORES); SCORES = (float *)malloc(MAX_POS_ * sizeof(float));

    POS_ = 0;
}

void slop_reset() {
    POS_ = 0;
}

/* Forward one token, then sample the next.
 *   token_id    integer in [0, vocab_size)
 *   temperature <= 0 means greedy (argmax), > 0 applies softmax scaling
 *   top_k       0 or >vocab means use the full distribution
 *   rand_u      a uniform [0,1) — drawn on the Perl side per call so
 *               srand() / explicit RNGs stay reproducible
 * Returns the sampled token id. */
int slop_forward_sample(int token_id, double temperature, int top_k, double rand_u) {
    if (POS_ >= MAX_POS_) return 2;  /* out of room: emit EOS */

    /* Embedding lookup. */
    memcpy(XBUF, W_EMBED + (size_t)token_id * H_, H_ * sizeof(float));

    /* RMSNorm 1. */
    rmsnorm(FBUF, XBUF, W_LN1, H_, RMS_EPS_);

    /* Q/K/V projections. */
    matvec(QBUF, W_Q, FBUF, H_,  H_);
    matvec(KBUF, W_K, FBUF, KV_, H_);
    matvec(VBUF, W_V, FBUF, KV_, H_);

    /* RoPE on Q and K. */
    apply_rope(QBUF, NH_, POS_);
    apply_rope(KBUF, NK_, POS_);

    /* Append K, V to the cache. */
    memcpy(KCACHE + (size_t)POS_ * KV_, KBUF, KV_ * sizeof(float));
    memcpy(VCACHE + (size_t)POS_ * KV_, VBUF, KV_ * sizeof(float));

    /* Multi-head attention. GQA: kv_head = q_head / GRP. */
    {
        int T = POS_ + 1;
        memset(CTXBUF, 0, H_ * sizeof(float));
        int h;
        for (h = 0; h < NH_; h++) {
            int kvh    = h / GRP_;
            const float *qh   = QBUF + h * D_;
            int   kv_off      = kvh * D_;
            float maxs = -1e30f;
            int t, d;
            for (t = 0; t < T; t++) {
                const float *kt = KCACHE + (size_t)t * KV_ + kv_off;
                float s = 0.0f;
                for (d = 0; d < D_; d++) s += qh[d] * kt[d];
                s *= INV_SD_;
                SCORES[t] = s;
                if (s > maxs) maxs = s;
            }
            float sum = 0.0f;
            for (t = 0; t < T; t++) {
                SCORES[t] = expf(SCORES[t] - maxs);
                sum += SCORES[t];
            }
            float inv = 1.0f / sum;
            float *cout = CTXBUF + h * D_;
            for (t = 0; t < T; t++) {
                const float *vt = VCACHE + (size_t)t * KV_ + kv_off;
                float w = SCORES[t] * inv;
                for (d = 0; d < D_; d++) cout[d] += w * vt[d];
            }
        }
    }

    /* o_proj + residual. */
    matvec(OBUF, W_O, CTXBUF, H_, H_);
    {
        int i;
        for (i = 0; i < H_; i++) XBUF[i] += OBUF[i];
    }

    /* RMSNorm 2. */
    rmsnorm(FBUF, XBUF, W_LN2, H_, RMS_EPS_);

    /* SwiGLU FFN. */
    matvec(GBUF, W_GATE, FBUF, II_, H_);
    matvec(UBUF, W_UP,   FBUF, II_, H_);
    {
        int i;
        for (i = 0; i < II_; i++) {
            float gi = GBUF[i];
            GBUF[i] = gi / (1.0f + expf(-gi)) * UBUF[i];
        }
    }
    matvec(DBUF, W_DOWN, GBUF, H_, II_);
    {
        int i;
        for (i = 0; i < H_; i++) XBUF[i] += DBUF[i];
    }

    /* Final norm + LM head. */
    rmsnorm(FBUF, XBUF, W_LNF, H_, RMS_EPS_);
    matvec(LOGITS, W_LMHEAD, FBUF, V_, H_);

    POS_++;

    /* Sampling.
     *  - greedy when temperature <= 0
     *  - otherwise top-k with softmax(logits / temperature) */
    if (temperature <= 0.0) {
        int   best = 0;
        float bv   = LOGITS[0];
        int   i;
        for (i = 1; i < V_; i++) {
            if (LOGITS[i] > bv) {bv = LOGITS[i]; best = i;}
        }
        return best;
    }

    int k = top_k;
    if (k <= 0 || k > V_) k = V_;

    /* Heap-free top-k: keep two parallel arrays and replace-and-scan.
     * For k=50, V=32000 this is ~1.6M comparisons in tight C — well
     * under a millisecond. alloca() keeps it stack-local. */
    int   *top_ids  = (int   *)alloca((size_t)k * sizeof(int));
    float *top_vals = (float *)alloca((size_t)k * sizeof(float));
    {
        int j;
        for (j = 0; j < k; j++) {
            top_vals[j] = -1e30f;
            top_ids[j]  = 0;
        }
    }
    float min_in = -1e30f;
    int   min_at = 0;
    {
        int i, j;
        for (i = 0; i < V_; i++) {
            float l = LOGITS[i];
            if (l <= min_in) continue;
            top_vals[min_at] = l;
            top_ids[min_at]  = i;
            /* Re-find the minimum across the kept k. */
            min_in = top_vals[0];
            min_at = 0;
            for (j = 1; j < k; j++) {
                if (top_vals[j] < min_in) {min_in = top_vals[j]; min_at = j;}
            }
        }
    }

    /* Softmax over top-k, sample by CDF. */
    float maxv = top_vals[0];
    {
        int j;
        for (j = 1; j < k; j++) if (top_vals[j] > maxv) maxv = top_vals[j];
    }
    float *probs = (float *)alloca((size_t)k * sizeof(float));
    float  sum   = 0.0f;
    {
        int j;
        for (j = 0; j < k; j++) {
            probs[j] = expf((top_vals[j] - maxv) / (float)temperature);
            sum     += probs[j];
        }
    }
    double r = rand_u * (double)sum;
    double c = 0.0;
    {
        int j;
        for (j = 0; j < k; j++) {
            c += probs[j];
            if (r <= c) return top_ids[j];
        }
    }
    return top_ids[k - 1];
}
