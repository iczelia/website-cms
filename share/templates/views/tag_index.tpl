{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: {{ kind }} tags ::</h1>
      <p>all tags used across <a href="/{{ kind }}/">{{ kind }} posts</a>.</p>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
{% if tags %}      <ul class="ab-list-tags">
{% for t in tags %}        <li><a class="ab-tag" href="{{ t.url }}">{{ t.tag }}</a> <span class="ab-tag-count">({{ t.count }})</span></li>
{% endfor %}      </ul>
{% else %}      <p>no tags yet.</p>
{% endif %}    </section>
{% endblock %}
