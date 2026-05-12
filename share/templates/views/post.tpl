{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <p class="ab-post-meta">{% if post.kappa %}<span class="ab-kappa" title="{{ post.kappa_title }}">{{ post.kappa }}</span> {% endif %}&raquo; {{ post.date_fmt }}{% if post.word_count %} &middot; {{ post.word_count }} words{% endif %}{% if post.tags %} &middot; {% for t in post.tags %}<a class="ab-tag" href="/{{ post.kind }}/tag/{{ urlencode(t) }}/">{{ t }}</a>{% endfor %}{% endif %}</p>
      <h1 class="ab-h1">{{ post.title }}</h1>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section ab-post-body">
      {{{ post.body_html }}}
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
{% if post.kind %}      <a class="ab-back" href="/{{ post.kind }}/">&lt; back to {{ post.kind }}</a>
{% endif %}    </section>
{% endblock %}
