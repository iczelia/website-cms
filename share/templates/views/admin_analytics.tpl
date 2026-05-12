{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-analytics">
  <header class="cms-edit-head">
    <h1>analytics</h1>
    <p class="cms-meta">no client-side JS, no IPs stored. visitor_hash = sha256(ip + ua + daily salt) truncated to 16 hex.</p>
    <p class="cms-anal-controls">
      range:
      <a href="/admin/analytics/?range=7d{% if data.bots_hidden %}&bots=hide{% endif %}">7d</a> &middot;
      <a href="/admin/analytics/?range=30d{% if data.bots_hidden %}&bots=hide{% endif %}">30d</a> &middot;
      <a href="/admin/analytics/?range=all{% if data.bots_hidden %}&bots=hide{% endif %}">all</a>
      &nbsp; &middot; &nbsp;
      bots:
      <a href="/admin/analytics/?range={{ range }}">show</a> &middot;
      <a href="/admin/analytics/?range={{ range }}&bots=hide">hide</a>
      &nbsp; &middot; &nbsp;
      <a href="/admin/analytics/raw">raw events &raquo;</a>
    </p>
  </header>

  <section class="cms-anal-totals">
    <div><strong>{{ data.totals.views }}</strong> views</div>
    <div><strong>{{ data.totals.uniques }}</strong> uniques</div>
    <div><strong>{{ data.totals.bots }}</strong> bots</div>
  </section>

  <section class="cms-anal-block">
    <h2>views per day</h2>
    {{{ svg_views }}}
  </section>

  <section class="cms-anal-block">
    <h2>uniques per day</h2>
    {{{ svg_uniques }}}
  </section>

  <section class="cms-anal-block">
    <h2>top paths</h2>
    <table class="cms-table">
      <thead><tr><th>path</th><th>views</th><th>uniques</th><th>bots</th></tr></thead>
      <tbody>
{% for p in data.top_paths %}        <tr>
          <td><code>{{ p.path }}</code></td>
          <td>{{ p.views }}</td>
          <td>{{ p.uniques }}</td>
          <td>{{ p.bots }}</td>
        </tr>
{% endfor %}      </tbody>
    </table>
  </section>

  <section class="cms-anal-block">
    <h2>top referrers</h2>
{% if data.top_refs %}    <table class="cms-table">
      <thead><tr><th>host</th><th>visits</th></tr></thead>
      <tbody>
{% for r in data.top_refs %}        <tr>
          <td>{{ r.host }}</td>
          <td>{{ r.count }}</td>
        </tr>
{% endfor %}      </tbody>
    </table>
{% else %}    <p>no off-site referrers in this range.</p>
{% endif %}  </section>
</article>
{% endblock %}
