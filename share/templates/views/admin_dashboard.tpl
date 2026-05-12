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
    <p class="cms-meta">drops the response, tex, and per-row html caches. the next visitor pays a full re-render.</p>
    <form class="cms-form" method="POST" action="/admin/cache/drop"
          onsubmit="return confirm('drop ALL site caches? next visitor will pay a full re-render.')">
      <input type="hidden" name="csrf" value="{{ csrf.cache_drop }}">
      <button class="cms-btn cms-btn-danger" type="submit">drop all caches</button>
    </form>
    <p class="cms-meta">rebuild the search index from posts. cheap; safe to run any time.</p>
    <form class="cms-form" method="POST" action="/admin/search/rebuild">
      <input type="hidden" name="csrf" value="{{ csrf.search_rebuild }}">
      <button class="cms-btn" type="submit">rebuild search index</button>
    </form>
  </section>
</div>
{% endblock %}
