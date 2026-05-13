{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: theme preview ::</h1>
      <p>every highlighter token class plus a handful of real snippets, rendered with the live <code>theme.code.*</code> settings. tweak settings, hit save, refresh this page to compare.</p>
      <p><a href="/admin/settings/">&lt; back to settings</a></p>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section ab-post-body">
      <h2>token classes</h2>
      <table class="cms-table">
        <thead><tr><th>class</th><th>swatch</th></tr></thead>
        <tbody>
          {% for c in classes %}
            <tr><td><code>hl-{{ c }}</code></td><td><pre class="hl"><code><span class="hl-{{ c }}">sample text {{ c }}</span></code></pre></td></tr>
          {% endfor %}
        </tbody>
      </table>
      <h2>code samples</h2>
      {% for s in samples %}
        <h3>{{ s.lang }}</h3>
        {{{ s.html }}}
      {% endfor %}
      <h2>inside a blockquote</h2>
      <blockquote>
        <p>quoted text with <code>inline code</code> in the middle &mdash; the inline-code rule is italic by default; check it doesn't fight the box.</p>
        {{{ blockquote_sample_html }}}
      </blockquote>
    </section>
{% endblock %}
