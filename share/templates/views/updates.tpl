{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: updates ::</h1>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
{% if items %}      <ul class="ab-list-updates">
{% for u in items %}        <li><span class="ab-upd-date">>> {{ u.date_fmt }}</span> <span class="ab-upd-text">{{{ u.body_html }}}</span></li>
{% endfor %}      </ul>
{% else %}      <p>no updates yet.</p>
{% endif %}    </section>
{% endblock %}
