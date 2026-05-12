{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-list-page">
  <header class="cms-edit-head">
    <h1>revisions: {{ kind }}/{{ slug }}</h1>
    <p><a class="cms-btn cms-btn-cancel" href="/admin/{{ kind }}/{{ slug }}/edit">&lt; back to edit</a></p>
  </header>

{% if revisions %}  <table class="cms-table">
    <thead><tr><th>rev</th><th>title</th><th>date</th><th>author</th><th>captured</th><th>status</th><th></th><th></th></tr></thead>
    <tbody>
{% for r in revisions %}      <tr>
        <td><code>#{{ r.revision_num }}</code></td>
        <td>{{ r.title }}</td>
        <td>{{ r.date }}</td>
        <td>{{ r.author }}</td>
        <td>{{ r.created_fmt }}</td>
        <td>{% if r.draft %}<span class="cms-badge cms-badge-draft">draft</span>{% else %}published{% endif %}</td>
        <td><a href="/admin/{{ kind }}/{{ slug }}/revisions/{{ r.revision_num }}">view</a></td>
        <td>
          <form method="POST" action="/admin/{{ kind }}/{{ slug }}/revisions/{{ r.revision_num }}/restore" class="cms-inline-form">
            <input type="hidden" name="csrf" value="{{ r.csrf_restore }}">
            <button type="submit" class="cms-btn" onclick="return confirm('restore this revision?')">restore</button>
          </form>
        </td>
      </tr>
{% endfor %}    </tbody>
  </table>
{% else %}  <p>no revisions yet. revisions are captured on every save.</p>
{% endif %}</article>
{% endblock %}
