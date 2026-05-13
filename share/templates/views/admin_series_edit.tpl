{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{{ title }}</h1>
  </header>

{% if error %}  <p class="cms-error">{{ error }}</p>
{% endif %}

  <form class="cms-form" method="POST" action="{{ form_action }}">
    <input type="hidden" name="csrf" value="{{ csrf_form }}">
    <table class="cms-settings"><tbody>
      <tr><td><label for="s_slug">slug</label></td>
          <td><input id="s_slug" type="text" name="slug" value="{{ rec.slug }}" placeholder="auto from title"></td></tr>
      <tr><td><label for="s_title">title</label></td>
          <td><input id="s_title" type="text" name="title" value="{{ rec.title }}" required></td></tr>
      <tr><td><label for="s_desc">description</label></td>
          <td><textarea id="s_desc" class="cm-md" name="description" rows="6">{{ rec.description }}</textarea></td></tr>
    </tbody></table>
    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/series/">cancel</a>
    </p>
  </form>
</article>
{% endblock %}
