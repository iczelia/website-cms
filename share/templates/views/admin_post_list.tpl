{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-list-page">
  <header class="cms-edit-head">
    <h1>{{ kind }} posts</h1>
    <p><a class="cms-btn cms-btn-primary" href="/admin/{{ kind }}/new">+ new {{ kind }} post</a></p>
  </header>

{% if posts %}  <table class="cms-table">
    <thead><tr><th>title</th><th>slug</th><th>date</th><th>status</th><th></th></tr></thead>
    <tbody>
{% for p in posts %}      <tr>
        <td><a href="/admin/{{ kind }}/{{ p.slug }}/edit">{{ p.title }}</a></td>
        <td><code>{{ p.slug }}</code></td>
        <td>{{ p.date }}</td>
        <td><span class="cms-badge {{ p.status_cls }}">{{ p.status }}</span></td>
        <td><a href="/{{ kind }}/{{ p.slug }}/" target="_blank" rel="noopener">view</a></td>
      </tr>
{% endfor %}    </tbody>
  </table>
{% else %}  <p>no posts yet.</p>
{% endif %}</article>
{% endblock %}
