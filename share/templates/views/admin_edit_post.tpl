{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{% if post.id %}edit{% else %}new{% endif %} {{ kind }} post</h1>
    {% if post.id %}<p class="cms-meta">slug: <code>{{ post.slug }}</code> &middot; last edited {{ post.updated_fmt }}{% if post.word_count %} &middot; {{ post.word_count }} words{% endif %} &middot; <a href="/admin/{{ kind }}/{{ post.slug }}/revisions">revisions</a></p>{% endif %}
  </header>

  <form class="cms-form cms-edit-post" method="POST" action="{{ form_action }}">
    <input type="hidden" name="csrf" value="{{ csrf_form }}">

    <div class="cms-edit-grid">
      <div class="cms-edit-main">
        <fieldset class="cms-field cms-field-text">
          <legend>title</legend>
          <input type="text" name="title" value="{{ post.title }}" required maxlength="200">
        </fieldset>

        <fieldset class="cms-field cms-field-markdown cms-field-split">
          <legend>body</legend>
          <div class="cms-edit-split">
            <textarea class="cm-md" name="body" rows="24">{{ post.body }}</textarea>
            <div class="cms-server-preview" id="server-preview"></div>
          </div>
        </fieldset>
      </div>

      <aside class="cms-edit-side">
        <fieldset class="cms-field cms-field-text">
          <legend>date</legend>
          <input type="date" name="date" value="{{ post.date }}" required>
        </fieldset>
        <fieldset class="cms-field cms-field-text">
          <legend>slug</legend>
          <input type="text" name="slug" value="{{ post.slug }}" pattern="[a-z0-9-]+" maxlength="80">
{% if post.aliases %}          <ul class="cms-aliases">
{% for a in post.aliases %}            <li><code>/{{ kind }}/{{ a.from_slug }}/</code> &rarr; current
              <form method="POST" action="/admin/{{ kind }}/{{ post.slug }}/aliases/{{ a.from_slug }}/delete" class="cms-inline-form">
                <input type="hidden" name="csrf" value="{{ a.csrf_del }}">
                <button type="submit" class="cms-btn cms-btn-tiny" onclick="return confirm('drop this alias?')">drop</button>
              </form></li>
{% endfor %}          </ul>
{% endif %}        </fieldset>
        <fieldset class="cms-field cms-field-text">
          <legend>tags</legend>
          <input type="text" name="tags" value="{{ post.tags }}" placeholder="comma, separated">
        </fieldset>
        <fieldset class="cms-field cms-field-bool">
          <label><input type="checkbox" name="draft" value="1"{% if post.draft %} checked{% endif %}> draft</label>
        </fieldset>
        <fieldset class="cms-field cms-field-text">
          <legend>publish at (UTC)</legend>
          <input type="datetime-local" name="publish_at" value="{{ post.publish_at_fmt }}">
          <small class="cms-help">leave blank to publish immediately when not draft</small>
        </fieldset>
      </aside>
    </div>

    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/{{ kind }}/">cancel</a>
{% if post.id %}      <button type="submit" formaction="/admin/{{ kind }}/{{ post.slug }}/delete" formmethod="POST" class="cms-btn cms-btn-danger" onclick="return confirm('delete this post?')">delete</button>
{% endif %}    </p>
  </form>
</article>
{% endblock %}
