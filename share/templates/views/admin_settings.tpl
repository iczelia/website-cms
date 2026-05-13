{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{{ title }}</h1>
  </header>

  <form class="cms-form" method="POST" action="{{ form_action }}">
    <input type="hidden" name="csrf" value="{{ form_csrf }}">
    {% for g in groups %}
      <fieldset class="cms-settings-group cms-settings-group-{{ g.id }}">
        <legend>{{ g.label }}</legend>
        <table class="cms-settings"><tbody>
          {% for f in g.fields %}
            <tr>
              <td><label for="s_{{ f.key }}">{{ f.display }}</label></td>
              <td><input id="s_{{ f.key }}" type="text" name="{{ f.key }}" value="{{ f.value }}"></td>
            </tr>
          {% endfor %}
        </tbody></table>
      </fieldset>
    {% endfor %}
    <p class="cms-help"><a href="/admin/settings/theme-preview" target="_blank" rel="noopener">preview the current code theme &raquo;</a></p>
    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/">cancel</a>
    </p>
  </form>
</article>
{% endblock %}
