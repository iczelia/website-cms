{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{{ kind }}/{{ slug }} rev #{{ rev.revision_num }}</h1>
    <p class="cms-meta">
      captured {{ rev.created_fmt }}
      {% if rev.author %}| by {{ rev.author }}{% endif %}
      | <a href="/admin/{{ kind }}/{{ slug }}/revisions">all revisions</a>
      | <a href="/admin/{{ kind }}/{{ slug }}/edit">current</a>
    </p>
  </header>

  <section class="cms-rev-fields">
    <p><strong>title:</strong> {{ rev.title }}</p>
    <p><strong>date:</strong> {{ rev.date }}</p>
    <p><strong>tags:</strong> {{ rev.tags }}</p>
    <p><strong>status:</strong>
      {% if rev.draft %}draft{% else %}published{% endif %}
    </p>
  </section>

  <section class="cms-rev-body">
    <h2>body</h2>
    <pre class="cms-rev-source">{{ rev.body }}</pre>
  </section>

  <form method="POST" action="/admin/{{ kind }}/{{ slug }}/revisions/{{ rev.revision_num }}/restore">
    <input type="hidden" name="csrf" value="{{ csrf_restore }}">
    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary" onclick="return confirm('restore this revision as the current version?')">restore as current</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/{{ kind }}/{{ slug }}/revisions">cancel</a>
    </p>
  </form>
</article>
{% endblock %}
