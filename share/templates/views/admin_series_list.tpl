{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{{ title }}</h1>
    <p><a class="cms-btn cms-btn-primary" href="/admin/series/new">new series</a></p>
  </header>

  <table class="cms-table">
    <thead><tr><th>slug</th><th>title</th><th>posts</th><th>updated</th><th></th></tr></thead>
    <tbody>
{% for r in rows %}      <tr>
        <td><a href="/admin/series/{{ r.id }}/edit">{{ r.slug }}</a></td>
        <td>{{ r.title }}</td>
        <td>{{ r.post_count }}</td>
        <td>{{ r.updated_fmt }}</td>
        <td>
          <form class="cms-inline-form" method="POST" action="/admin/series/{{ r.id }}/delete" onsubmit="return confirm('delete series {{ r.slug }}? posts in it stay; they just lose the series link.')">
            <input type="hidden" name="csrf" value="{{ r.csrf_del }}">
            <button type="submit" class="cms-btn cms-btn-danger">delete</button>
          </form>
        </td>
      </tr>
{% endfor %}    </tbody>
  </table>
</article>
{% endblock %}
