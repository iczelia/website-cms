{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: cv ::</h1>
      {{{ data.intro_html }}}
    </section>

{% if data.experience %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; experience</h2>
      {{{ data.experience_html }}}
    </section>
{% endif %}

{% if data.education %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; education</h2>
      {{{ data.education_html }}}
    </section>
{% endif %}

{% if data.works %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; selected works</h2>
      {{{ data.works_html }}}
    </section>
{% endif %}

{% if data.pdf_url %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <p><a href="{{ data.pdf_url }}">&gt; download cv as pdf</a></p>
    </section>
{% endif %}
{% endblock %}
