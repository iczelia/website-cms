{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-analytics">
  <header class="cms-edit-head">
    <h1>raw events</h1>
    <p class="cms-meta">latest 200 entries from <code>analytics_events</code>. older events are rolled into daily aggregates by the in-process aggregator.</p>
    <p><a class="cms-btn cms-btn-cancel" href="/admin/analytics/">&lt; back to dashboard</a></p>
  </header>

{% if events %}  <table class="cms-table">
    <thead><tr><th>ts (UTC)</th><th>method</th><th>path</th><th>status</th><th>visitor</th><th>ua_class</th><th>referer</th></tr></thead>
    <tbody>
{% for e in events %}      <tr>
        <td>{{ e.ts_fmt }}</td>
        <td>{{ e.method }}</td>
        <td><code>{{ e.path }}</code></td>
        <td>{{ e.status }}</td>
        <td><code>{{ e.visitor_hash }}</code></td>
        <td>{{ e.ua_class }}</td>
        <td>{{ e.referer_host }}</td>
      </tr>
{% endfor %}    </tbody>
  </table>
{% else %}  <p>no recent events.</p>
{% endif %}</article>
{% endblock %}
