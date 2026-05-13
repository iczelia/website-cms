{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <p class="ab-post-meta">{% if post.kappa %}<span class="ab-kappa" title="{{ post.kappa_title }}">{{ post.kappa }}</span> {% endif %}&raquo; {{ post.date_fmt }}{% if post.word_count %} &middot; {{ post.word_count }} words{% endif %}{% if post.read_min %} &middot; {{ post.read_min }} min read{% endif %}{% if post.tags %} &middot; {% for t in post.tags %}<a class="ab-tag" href="/{{ post.kind }}/tag/{{ urlencode(t) }}/">{{ t }}</a>{% endfor %}{% endif %}</p>
      <h1 class="ab-h1">{{ post.title }}</h1>
{% if post.series %}      <p class="ab-series-banner">part {{ post.series.position }} of the <a href="{{ post.series.url }}">{{ post.series.title }}</a> series</p>
{% endif %}    </section>

    <div class="ab-rule"></div>

{% if post.toc %}
    <nav class="ab-toc" aria-label="table of contents">
      <p class="ab-toc-head">contents</p>
      <ol class="ab-toc-list">
{% for item in post.toc.items %}        <li class="ab-toc-h{{ item.level }}"><a href="#{{ item.id }}">{{ item.text }}</a></li>
{% endfor %}      </ol>
    </nav>

    <div class="ab-rule"></div>
{% endif %}

    <section class="ab-section ab-post-body">
      {{{ post.body_html }}}
    </section>

    <div class="ab-rule"></div>

{% if post.series %}
    <nav class="ab-section ab-series-nav" aria-label="series navigation">
{% if post.series.prev %}      <a class="ab-series-prev" href="{{ post.series.prev.url }}">&laquo; {{ post.series.prev.title }}</a>
{% endif %}      <a class="ab-series-up" href="{{ post.series.url }}">{{ post.series.title }} index</a>
{% if post.series.next %}      <a class="ab-series-next" href="{{ post.series.next.url }}">{{ post.series.next.title }} &raquo;</a>
{% endif %}    </nav>

    <div class="ab-rule"></div>
{% endif %}

    <section class="ab-section">
{% if post.kind %}      <a class="ab-back" href="/{{ post.kind }}/">&lt; back to {{ post.kind }}</a>
{% endif %}    </section>
{% endblock %}
