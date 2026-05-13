{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">{{ series.title }}</h1>
      <p class="ab-post-meta">a series of {{ series.post_count }} post{% if series.post_count %}{% endif %}</p>
{% if series.intro_html %}      {{{ series.intro_html }}}
{% endif %}    </section>

    <div class="ab-rule"></div>

    <section class="ab-section ab-series-list">
      <ol class="ab-series-posts">
{% for p in series.posts %}        <li><a href="{{ p.url }}"><span class="ab-series-pos">{{ p.position }}.</span> {{ p.title }}</a> <span class="ab-series-date">{{ p.date_fmt }}</span></li>
{% endfor %}      </ol>
    </section>
{% endblock %}
