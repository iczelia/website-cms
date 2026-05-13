{% extends "layouts/admin.tpl" %}
{% block content %}
<div class="cms-grid">
  <section class="cms-card">
    <h2>pages</h2>
    <ul class="cms-list">
{% for p in pages %}      <li><a href="/admin/edit/{{ p.slug }}">{{ p.title }}</a> <span class="cms-meta">{{ p.updated_fmt }}</span></li>
{% endfor %}    </ul>
  </section>

  <section class="cms-card">
    <h2>blog</h2>
    <p><a class="cms-btn" href="/admin/blog/new">+ new post</a></p>
    <ul class="cms-list">
{% for p in blog %}      <li><a href="/admin/blog/{{ p.slug }}/edit">{{ p.title }}</a> <span class="cms-meta">{{ p.date }}{% if p.draft %} · draft{% endif %}</span></li>
{% endfor %}    </ul>
  </section>

  <section class="cms-card">
    <h2>journal</h2>
    <p><a class="cms-btn" href="/admin/journal/new">+ new entry</a></p>
    <ul class="cms-list">
{% for p in journal %}      <li><a href="/admin/journal/{{ p.slug }}/edit">{{ p.title }}</a> <span class="cms-meta">{{ p.date }}{% if p.draft %} · draft{% endif %}</span></li>
{% endfor %}    </ul>
  </section>

  <section class="cms-card">
    <h2>extras</h2>
    <ul class="cms-list">
      <li><a href="/admin/dynamic/">dynamic pages</a> -add top-level routes</li>
      <li><a href="/admin/highlight/">highlighter languages</a> -admin-defined languages</li>
      <li><a href="/admin/analytics/">analytics</a> -views, uniques, referrers</li>
      <li><a href="/admin/backup/">backup / export / import / wipe</a></li>
    </ul>
  </section>

  <section class="cms-card">
    <h2>math cache</h2>
    <p class="cms-meta">{{ math.cached }} / {{ math.total }} fragments rendered ({{ math.pct }}% full). cache rows: {{ math.cache_rows }}.{% if math.missing %} {{ math.missing }} missing - background warmer will fill within 60s.{% endif %}</p>
  </section>

  <section class="cms-card">
    <h2>maintenance</h2>
    <p class="cms-meta"><b>drop</b> wipes the response, tex, and per-row html caches; the next visitor pays a full re-render. <b>rebuild html</b> re-renders pages/posts on top of the existing math cache. <b>rebuild all</b> additionally rebuilds the math cache from scratch.</p>
    <div class="cms-btn-row" style="display:flex;flex-wrap:wrap;gap:0.5em;align-items:center;">
      <form class="cms-form" method="POST" action="/admin/cache/drop"
            onsubmit="return confirm('drop ALL site caches? next visitor will pay a full re-render.')">
        <input type="hidden" name="csrf" value="{{ csrf.cache_drop }}">
        <button class="cms-btn cms-btn-danger" type="submit">drop all caches</button>
      </form>
      <form class="cms-form" method="POST" action="/admin/cache/rebuild"
            onsubmit="return confirm('re-render every page and post? math cache stays. runs in the background.')">
        <input type="hidden" name="csrf"  value="{{ csrf.cache_rebuild }}">
        <input type="hidden" name="scope" value="html">
        <button class="cms-btn" type="submit">rebuild html</button>
      </form>
      <form class="cms-form" method="POST" action="/admin/cache/rebuild"
            onsubmit="return confirm('drop and re-render ALL caches (math + html)? this can take a while. runs in the background.')">
        <input type="hidden" name="csrf"  value="{{ csrf.cache_rebuild }}">
        <input type="hidden" name="scope" value="all">
        <button class="cms-btn cms-btn-danger" type="submit">rebuild all caches</button>
      </form>
    </div>
{% if rebuild %}    <div id="rebuild-progress"
         data-phase="{{ rebuild.phase }}"
         data-scope="{{ rebuild.scope }}"
         data-total="{{ rebuild.total }}"
         data-done="{{ rebuild.done }}"
         data-started="{{ rebuild.started_at }}"
         data-finished="{{ rebuild.finished_at }}"
         data-error="{{ rebuild.error }}"
         style="margin-top:0.75em;">
      <div style="display:flex;align-items:center;gap:0.5em;">
        <div class="cms-meta" id="rebuild-label" style="flex:1;">starting...</div>
        <form id="rebuild-cancel-form" class="cms-form" method="POST" action="/admin/cache/rebuild/cancel"
              onsubmit="return confirm('cancel the running rebuild?')" style="margin:0;">
          <input type="hidden" name="csrf" value="{{ csrf.cache_rebuild_cancel }}">
          <button class="cms-btn cms-btn-danger" type="submit">cancel</button>
        </form>
      </div>
      <div style="background:#222;border:1px solid #444;height:8px;margin-top:0.25em;">
        <div id="rebuild-bar" style="background:#7a9;height:100%;width:0%;transition:width .4s;"></div>
      </div>
    </div>
    <script>
    (function() {
      var el = document.getElementById('rebuild-progress');
      if (!el) return;
      var bar = document.getElementById('rebuild-bar');
      var label = document.getElementById('rebuild-label');
      var timer = null;
      var stopped = false;
      function fmtSecs(s) {
        if (s < 60) return s + 's';
        var m = Math.floor(s / 60), r = s % 60;
        return m + 'm' + (r < 10 ? '0' : '') + r + 's';
      }
      var cancelForm = document.getElementById('rebuild-cancel-form');
      function hideCancel() { if (cancelForm) cancelForm.style.display = 'none'; }
      function paint(s) {
        var pct = s.total > 0 ? Math.round(s.done * 100 / s.total)
                              : (s.phase === 'done' ? 100 : (s.phase === 'math' ? 50 : 5));
        bar.style.width = pct + '%';
        var elapsed = s.started_at ? Math.max(0, Math.floor(Date.now()/1000 - s.started_at)) : 0;
        var scope = s.scope || el.dataset.scope || 'all';
        var msg;
        if (s.phase === 'done') {
          var took = (s.finished_at && s.started_at) ? (s.finished_at - s.started_at) : elapsed;
          msg = 'rebuild (' + scope + ') complete: ' + s.done + '/' + s.total + ' in ' + fmtSecs(took) + '.';
          bar.style.background = '#7c9';
          hideCancel();
        } else if (s.phase === 'error') {
          msg = 'rebuild (' + scope + ') failed after ' + fmtSecs(elapsed) + ': ' + (s.error || 'unknown error');
          bar.style.background = '#c66';
          hideCancel();
        } else if (s.phase === 'cancelled') {
          msg = 'rebuild (' + scope + ') cancelled after ' + fmtSecs(elapsed) + '.';
          bar.style.background = '#c93';
          hideCancel();
        } else if (s.phase === 'cancelling') {
          msg = 'cancelling rebuild (' + scope + ')... ' + fmtSecs(elapsed);
          bar.style.background = '#c93';
        } else if (s.phase === 'starting') {
          msg = 'starting (' + scope + ')... ' + fmtSecs(elapsed);
        } else if (s.phase === 'math') {
          msg = s.total > 0
            ? 'warming math cache (' + s.done + '/' + s.total + ', ' + pct + '%) - ' + fmtSecs(elapsed)
            : 'warming math cache... ' + fmtSecs(elapsed);
        } else if (s.phase === 'html') {
          msg = 'rendering pages/posts (' + s.done + '/' + s.total + ', ' + pct + '%) - ' + fmtSecs(elapsed);
        } else {
          msg = 'phase: ' + s.phase + ' - ' + fmtSecs(elapsed);
        }
        label.textContent = msg;
      }
      function stop() {
        stopped = true;
        if (timer) { clearTimeout(timer); timer = null; }
      }
      var TERMINAL = { done: 1, error: 1, cancelled: 1, idle: 1 };
      function tick() {
        if (stopped) return;
        timer = null;
        fetch('/admin/cache/rebuild/status', { credentials: 'same-origin', cache: 'no-store' })
          .then(function(r) { return r.json(); })
          .then(function(s) {
            if (stopped) return;
            paint(s);
            if (TERMINAL[s.phase]) {
              stop();
              if (s.phase === 'done') setTimeout(function() { location.reload(); }, 2000);
              return;
            }
            timer = setTimeout(tick, 1000);
          })
          .catch(function() {
            if (stopped) return;
            timer = setTimeout(tick, 2500);
          });
      }
      var initial = {
        phase:       el.dataset.phase,
        scope:       el.dataset.scope,
        total:       +el.dataset.total || 0,
        done:        +el.dataset.done  || 0,
        started_at:  +el.dataset.started  || 0,
        finished_at: +el.dataset.finished || 0,
        error:       el.dataset.error
      };
      paint(initial);
      if (!TERMINAL[initial.phase]) {
        tick();
      }
    })();
    </script>
{% endif %}
    <p class="cms-meta">rebuild the search index from posts. cheap; safe to run any time.</p>
    <form class="cms-form" method="POST" action="/admin/search/rebuild">
      <input type="hidden" name="csrf" value="{{ csrf.search_rebuild }}">
      <button class="cms-btn" type="submit">rebuild search index</button>
    </form>
  </section>
</div>
{% endblock %}
