{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>edit page: {{ page.slug }}</h1>
    <p class="cms-meta">template: <code>{{ page.template }}</code> | last edited {{ page.updated_fmt }}</p>
  </header>

  <form class="cms-form" method="POST" action="/admin/edit/{{ page.slug }}">
    <input type="hidden" name="csrf" value="{{ csrf_form }}">
{% for f in fields %}    <fieldset class="cms-field cms-field-{{ f.kind }}">
      <legend>{{ f.label }}</legend>
{% if f.help %}      <p class="cms-help">{{ f.help }}</p>
{% endif %}      {{{ f.input_html }}}
    </fieldset>
{% endfor %}    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/">cancel</a>
    </p>
  </form>
</article>
{% endblock %}
