{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: journal :: {{ cur_year }}</h1>
      {{{ data.intro_html }}}
      <p class="ab-filter">
{% if prev_year %}<a class="ab-year-nav" href="/journal/year/{{ prev_year }}/">&lt; {{ prev_year }}</a>{% else %}<span class="ab-year-nav-off">&lt; {{ cur_year }}</span>{% endif %}
        &middot;
{% if next_year %}<a class="ab-year-nav" href="/journal/year/{{ next_year }}/">{{ next_year }} &gt;</a>{% else %}<span class="ab-year-nav-off">{{ cur_year }} &gt;</span>{% endif %}
        &middot; <span class="ab-year-list">{% for y in years %}{% if y.current %}<span class="ab-year ab-year-current">{{ y.year }}</span>{% else %}<a class="ab-year" href="/journal/year/{{ y.year }}/">{{ y.year }}</a>{% endif %} {% endfor %}</span>
        &middot; <a href="/journal/tags/">tags</a>
      </p>
    </section>

    <div class="ab-rule"></div>

{% for e in entries %}    <section class="ab-section ab-journal-entry">
      <p class="ab-post-meta">{% if e.kappa %}<span class="ab-kappa" title="{{ e.kappa_title }}">{{ e.kappa }}</span> {% endif %}&raquo; <a href="/journal/{{ e.slug }}/">{{ e.date_fmt }}</a>{% if e.tags %} <span class="ab-post-tags">{% for t in e.tags %}<a class="ab-tag" href="/journal/tag/{{ urlencode(t) }}/">{{ t }}</a>{% endfor %}</span>{% endif %}</p>
      <div class="ab-post-body">{{{ e.body_html }}}</div>
    </section>

    <div class="ab-rule"></div>

{% endfor %}    <section class="ab-section">
      <p class="ab-filter">
{% if prev_year %}<a class="ab-year-nav" href="/journal/year/{{ prev_year }}/">&lt; {{ prev_year }}</a>{% endif %}
{% if next_year %} &middot; <a class="ab-year-nav" href="/journal/year/{{ next_year }}/">{{ next_year }} &gt;</a>{% endif %}
      </p>
    </section>
{% endblock %}
