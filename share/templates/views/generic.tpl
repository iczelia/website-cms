{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: {{ title_short }} ::</h1>
{% if data.intro_html %}      <div class="ab-intro">{{{ data.intro_html }}}</div>
{% endif %}    </section>

    <div class="ab-rule"></div>

    <section class="ab-section ab-post-body">
      {{{ data.body_html }}}
    </section>
{% endblock %}
