{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{% if row %}edit dynamic page{% else %}new dynamic page{% endif %}</h1>
{% if row %}    <p class="cms-meta">route: <code>{{ row.route }}</code></p>
{% endif %}    {% if error %}<p class="cms-error">{{ error }}</p>{% endif %}
  </header>

  <form class="cms-form" method="POST" action="{{ form_action }}">
    <input type="hidden" name="csrf" value="{{ csrf_form }}">

    <fieldset class="cms-field cms-field-text">
      <legend>route</legend>
      <input type="text" name="route" value="{{ route_value }}" required pattern="^/[a-z0-9][a-z0-9/-]*/$" maxlength="120">
      <p class="cms-help">e.g. <code>/zine/</code>, <code>/about/now/</code>. lowercase, trailing slash, 1-4 segments.</p>
    </fieldset>

    <fieldset class="cms-field cms-field-text">
      <legend>title</legend>
      <input type="text" name="title" value="{{ title_value }}" required maxlength="200">
    </fieldset>

    <fieldset class="cms-field cms-field-text">
      <legend>template</legend>
      <select name="template">
{% for t in template_opts %}        <option value="{{ t.name }}"{% if t.name == current_tpl %} selected{% endif %}>{{ t.label }}</option>
{% endfor %}      </select>
    </fieldset>

{% for f in fields_html %}    <fieldset class="cms-field cms-field-{{ f.kind }}">
      <legend>{{ f.label }}</legend>
{% if f.help %}      <p class="cms-help">{{ f.help }}</p>
{% endif %}      {{{ f.input_html }}}
    </fieldset>
{% endfor %}
    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/dynamic/">cancel</a>
{% if row %}      <button type="submit" formaction="/admin/dynamic/{{ row.id }}/delete" formmethod="POST" class="cms-btn cms-btn-danger" onclick="return confirm('delete this dynamic page?')">delete</button>
{% endif %}    </p>
  </form>
</article>
{% endblock %}
