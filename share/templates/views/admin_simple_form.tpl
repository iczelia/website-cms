{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{{ title }}</h1>
  </header>

  <form class="cms-form" method="POST" action="{{ form_action }}">
    <input type="hidden" name="csrf" value="{{ form_csrf }}">
    {{{ form_body }}}
    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/">cancel</a>
    </p>
  </form>
</article>
{% endblock %}
