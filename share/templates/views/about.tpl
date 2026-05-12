{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: about ::</h1>
      {{{ data.intro_html }}}
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; vital statistics</h2>
      <table class="ab-vitals">
{% for row in data.vitals %}        <tr><td>{{ row.key }}</td>  <td>{{{ row.value_html }}}</td></tr>
{% endfor %}      </table>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; elsewhere on the wires</h2>
      <ul class="ab-links">
{% for link in data.elsewhere %}        <li><span class="ab-where">{{ link.where }}</span> {% if link.url %}<a href="{{ link.url }}">{{ link.label }}</a>{% else %}{{{ link.label_html }}}{% endif %}</li>
{% endfor %}      </ul>
    </section>

{% if data.reach_out %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      {{{ data.reach_out_html }}}
    </section>
{% endif %}

{% if data.employment %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; employment</h2>
      {{{ data.employment_html }}}
    </section>
{% endif %}

{% if data.talks %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; talks, guest lectures and papers</h2>
      {{{ data.talks_html }}}
    </section>
{% endif %}

{% if data.links %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; links</h2>
      {{{ data.links_html }}}
    </section>
{% endif %}

{% if data.hardware %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; hardware</h2>
      {{{ data.hardware_html }}}
    </section>
{% endif %}

{% if data.setup %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; setup</h2>
      {{{ data.setup_html }}}
    </section>
{% endif %}

{% if data.patreon %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; patreon</h2>
      {{{ data.patreon_html }}}
    </section>
{% endif %}

{% if data.misc %}
    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; misc</h2>
      {{{ data.misc_html }}}
    </section>
{% endif %}

{% if data.qr %}
    <div class="ab-rule"></div>

    <section class="ab-section ab-qr">
      {{{ data.qr_html }}}
    </section>
{% endif %}

    <div class="ab-rule"></div>

    <section class="ab-section">
      <a class="ab-back" href="/">&lt; back to the front page</a>
    </section>
{% endblock %}
