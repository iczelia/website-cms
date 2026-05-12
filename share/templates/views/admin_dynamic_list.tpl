{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-list-page">
  <header class="cms-edit-head">
    <h1>dynamic pages</h1>
    <p>top-level routes added from the CMS, served alongside the built-in pages.</p>
    <p><a class="cms-btn cms-btn-primary" href="/admin/dynamic/new">+ new dynamic page</a></p>
  </header>

{% if pages %}  <table class="cms-table">
    <thead><tr><th>route</th><th>title</th><th>template</th><th>last edited</th><th></th><th></th></tr></thead>
    <tbody>
{% for p in pages %}      <tr>
        <td><a href="/admin/dynamic/{{ p.id }}/edit"><code>{{ p.route }}</code></a></td>
        <td>{{ p.title }}</td>
        <td>{{ p.template }}</td>
        <td>{{ p.updated_fmt }}</td>
        <td><a href="{{ p.route }}" target="_blank" rel="noopener">view</a></td>
        <td>
          <form method="POST" action="/admin/dynamic/{{ p.id }}/delete" class="cms-inline-form">
            <input type="hidden" name="csrf" value="{{ p.csrf_del }}">
            <button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('delete {{ p.route }}?')">delete</button>
          </form>
        </td>
      </tr>
{% endfor %}    </tbody>
  </table>
{% else %}  <p>no dynamic pages yet.</p>
{% endif %}</article>
{% endblock %}
