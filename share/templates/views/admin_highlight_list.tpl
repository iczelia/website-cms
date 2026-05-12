{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-list-page">
  <header class="cms-edit-head">
    <h1>highlighter languages</h1>
    <p>built-in languages always win. admin-defined names that collide with a built-in are silently shadowed at save time.</p>
    <p><a class="cms-btn cms-btn-primary" href="/admin/highlight/new">+ new language</a></p>
  </header>

  <h2>admin-defined</h2>
{% if langs %}  <table class="cms-table">
    <thead><tr><th>name</th><th>aliases</th><th>updated</th><th>version</th><th></th></tr></thead>
    <tbody>
{% for l in langs %}      <tr>
        <td><a href="/admin/highlight/{{ l.id }}/edit"><code>{{ l.name }}</code></a></td>
        <td>{{ l.aliases }}</td>
        <td>{{ l.updated_fmt }}</td>
        <td>{{ l.version }}</td>
        <td>
          <form method="POST" action="/admin/highlight/{{ l.id }}/delete" class="cms-inline-form">
            <input type="hidden" name="csrf" value="{{ l.csrf_del }}">
            <button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('delete language {{ l.name }}?')">delete</button>
          </form>
        </td>
      </tr>
{% endfor %}    </tbody>
  </table>
{% else %}  <p>none yet.</p>
{% endif %}

  <h2>built-in</h2>
  <p class="cms-meta"><code>{{ builtins_str }}</code></p>
</article>
{% endblock %}
