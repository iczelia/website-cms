{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: blog :: {{ cur_year }}</h1>
      {{{ data.intro_html }}}
      <p class="ab-filter">
{% if prev_year %}<a class="ab-year-nav" href="/blog/year/{{ prev_year }}/">&lt; {{ prev_year }}</a>{% else %}<span class="ab-year-nav-off">&lt; {{ cur_year }}</span>{% endif %}
        &middot;
{% if next_year %}<a class="ab-year-nav" href="/blog/year/{{ next_year }}/">{{ next_year }} &gt;</a>{% else %}<span class="ab-year-nav-off">{{ cur_year }} &gt;</span>{% endif %}
        &middot; <span class="ab-year-list">{% for y in years %}{% if y.current %}<span class="ab-year ab-year-current">{{ y.year }}</span>{% else %}<a class="ab-year" href="/blog/year/{{ y.year }}/">{{ y.year }}</a>{% endif %} {% endfor %}</span>
        &middot; <a href="/blog/tags/">tags</a>
      </p>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
{% if posts %}      <ul class="ab-list-posts">
{% for p in posts %}        <li>{% if p.kappa %}<span class="ab-kappa" title="{{ p.kappa_title }}">{{ p.kappa }}</span> {% endif %}<span class="ab-post-date">&raquo; {{ p.date_fmt }}</span> <a href="{{ p.url }}">{{ p.title }}</a>{% if p.tags %} <span class="ab-post-tags">{% for t in p.tags %}<a class="ab-tag" href="/blog/tag/{{ urlencode(t) }}/">{{ t }}</a>{% endfor %}</span>{% endif %}</li>
{% endfor %}      </ul>
{% else %}      <p>nothing in {{ cur_year }}.</p>
{% endif %}    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
      <p class="ab-filter">
{% if prev_year %}<a class="ab-year-nav" href="/blog/year/{{ prev_year }}/">&lt; {{ prev_year }}</a>{% endif %}
{% if next_year %} &middot; <a class="ab-year-nav" href="/blog/year/{{ next_year }}/">{{ next_year }} &gt;</a>{% endif %}
      </p>
    </section>
{% endblock %}
