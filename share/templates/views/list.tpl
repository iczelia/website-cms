{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: {{ title_short }} ::</h1>
      {{{ data.intro_html }}}
{% if tag_filter %}      <p class="ab-filter">filtered by tag: <span class="ab-tag">{{ tag_filter }}</span> &middot; <a href="/{{ slug }}/">clear filter</a> &middot; <a href="/{{ slug }}/tag/{{ urlencode(tag_filter) }}/feed.xml">tag feed</a></p>
{% else %}      <p class="ab-filter"><a href="/{{ slug }}/tags/">browse all tags</a></p>
{% endif %}    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
{% if posts %}      <ul class="ab-list-posts">
{% for p in posts %}        <li><span class="ab-post-date">&raquo; {{ p.date_fmt }}</span> <a href="{{ p.url }}">{{ p.title }}</a>{% if p.tags %} <span class="ab-post-tags">{% for t in p.tags %}<a class="ab-tag" href="/{{ slug }}/tag/{{ urlencode(t) }}/">{{ t }}</a>{% endfor %}</span>{% endif %}</li>
{% endfor %}      </ul>
{% else %}      <p>{% if tag_filter %}no posts with that tag.{% else %}nothing here yet.{% endif %}</p>
{% endif %}    </section>
{% endblock %}
