{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>guestbook moderation</h1>
  </header>

  <h2>pending</h2>
{% if pending %}{% for e in pending %}  <article class="gb-mod-entry gb-mod-pending">
    <header class="gb-mod-meta">
      <strong>{{ e.nickname }}</strong>
      <span class="cms-meta">{{ e.date_fmt }} | {{ e.ip }}</span>
    </header>
    <div class="gb-mod-preview">{{{ e.preview_html }}}</div>
    <div class="gb-mod-actions">
      <form method="POST" action="/admin/guestbook/{{ e.id }}/approve" class="cms-inline-form">
        <input type="hidden" name="csrf" value="{{ e.csrf_approve }}">
        <button class="cms-btn cms-btn-primary">approve</button>
      </form>
      <form method="POST" action="/admin/guestbook/{{ e.id }}/reject" class="cms-inline-form">
        <input type="hidden" name="csrf" value="{{ e.csrf_reject }}">
        <button class="cms-btn">reject</button>
      </form>
      <form method="POST" action="/admin/guestbook/{{ e.id }}/delete" class="cms-inline-form" onsubmit="return confirm('delete?')">
        <input type="hidden" name="csrf" value="{{ e.csrf_delete }}">
        <button class="cms-btn cms-btn-danger">delete</button>
      </form>
    </div>
  </article>
{% endfor %}{% else %}  <p>no pending entries.</p>
{% endif %}
  <h2>approved (recent)</h2>
{% if approved %}{% for e in approved %}  <article class="gb-mod-entry">
    <header class="gb-mod-meta">
      <strong>{{ e.nickname }}</strong>
      <span class="cms-meta">{{ e.date_fmt }}</span>
    </header>
    <div class="gb-mod-preview">{{{ e.body_html }}}</div>
{% if e.admin_reply_html %}    <div class="gb-mod-reply">
      <em>reply:</em> {{{ e.admin_reply_html }}}
    </div>
{% endif %}    <details class="gb-mod-reply-form">
      <summary>{% if e.admin_reply_html %}edit reply{% else %}reply{% endif %}</summary>
      <form method="POST" action="/admin/guestbook/{{ e.id }}/reply" class="cms-form">
        <input type="hidden" name="csrf" value="{{ e.csrf_reply }}">
        <textarea name="reply" rows="4" maxlength="4000"></textarea>
        <p><button class="cms-btn cms-btn-primary">save reply</button></p>
      </form>
    </details>
    <form method="POST" action="/admin/guestbook/{{ e.id }}/delete" class="cms-inline-form" onsubmit="return confirm('delete?')">
      <input type="hidden" name="csrf" value="{{ e.csrf_delete }}">
      <button class="cms-btn cms-btn-danger">delete</button>
    </form>
  </article>
{% endfor %}{% else %}  <p>no approved entries yet.</p>
{% endif %}</article>
{% endblock %}
