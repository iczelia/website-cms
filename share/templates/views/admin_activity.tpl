{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>activity</h1>
    <form method="POST" action="/admin/activity/refresh" class="cms-inline-form">
      <input type="hidden" name="csrf" value="{{ csrf.refresh }}">
      <button type="submit" class="cms-btn">refresh now</button>
    </form>
  </header>

  <form class="cms-form" method="POST" action="/admin/activity/currently">
    <input type="hidden" name="csrf" value="{{ csrf.currently }}">
    <fieldset class="cms-field cms-field-text">
      <legend>currently</legend>
      <input type="text" name="currently" value="{{ currently }}" maxlength="200">
      <p class="cms-help">free-text line shown in the activity panel.</p>
    </fieldset>
    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
    </p>
  </form>

  <h2>fetched feeds</h2>
{% for s in sections %}  <section class="cms-act-section">
    <h3>{{ s.source }}</h3>
{% if s.rows %}    <table class="cms-table">
      <thead><tr><th>text</th><th>posted</th></tr></thead>
      <tbody>
{% for r in s.rows %}        <tr><td>{% if r.url %}<a href="{{ r.url }}">{{ r.text }}</a>{% else %}{{ r.text }}{% endif %}</td><td><span class="cms-meta">{{ fmt_ago(r.posted_at) }}</span></td></tr>
{% endfor %}      </tbody>
    </table>
{% else %}    <p>no rows. configure the {{ s.source }} handle in settings, then click "refresh now".</p>
{% endif %}  </section>
{% endfor %}</article>
{% endblock %}
