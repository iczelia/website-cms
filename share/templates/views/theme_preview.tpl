{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: theme preview ::</h1>
      <p>every highlighter token class plus a handful of real snippets, rendered with the live <code>theme.code.*</code> settings. tweak settings, hit save, refresh this page to compare.</p>
      <p><a href="/admin/settings/">&lt; back to settings</a></p>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section ab-post-body">
      {{{ body_html }}}
    </section>
{% endblock %}
