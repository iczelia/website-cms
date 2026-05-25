{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-list-page">
  <header class="cms-edit-head">
    <h1>static subpages</h1>
    <p>upload a zip bundle of HTML/CSS/JS; it is served under <code>/&lt;slug&gt;/</code> with <code>index.html</code> as the default document.</p>
  </header>

{% if error %}  <p class="cms-error">{{ error }}</p>
{% endif %}{% if subpages %}  <table class="cms-table">
    <thead><tr><th>slug</th><th>title</th><th>files</th><th>last edited</th><th></th><th></th></tr></thead>
    <tbody>
{% for s in subpages %}      <tr>
        <td><a href="/admin/subpages/{{ s.id }}/edit"><code>/{{ s.slug }}/</code></a></td>
        <td>{{ s.title }}</td>
        <td>{{ s.file_count }}</td>
        <td>{{ s.updated_fmt }}</td>
        <td><a href="{{ s.url }}" target="_blank" rel="noopener">open</a></td>
        <td>
          <form method="POST" action="/admin/subpages/{{ s.id }}/delete" class="cms-inline-form">
            <input type="hidden" name="csrf" value="{{ s.csrf_del }}">
            <button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('delete subpage /{{ s.slug }}/ and all its files?')">delete</button>
          </form>
        </td>
      </tr>
{% endfor %}    </tbody>
  </table>
{% else %}  <p>no static subpages yet.</p>
{% endif %}
  <section class="cms-subpage-section">
    <h2>new subpage</h2>
    <form class="cms-form" method="POST" action="/admin/subpages/new" enctype="multipart/form-data" data-cms-upload="bundle">
      <input type="hidden" name="csrf" value="{{ csrf_form }}">
      <fieldset class="cms-field cms-field-text">
        <legend>slug</legend>
        <input type="text" name="slug" value="{{ slug_value }}" required pattern="[a-z0-9][a-z0-9-]*" maxlength="63" placeholder="jcram">
        <p class="cms-help">lowercase letters, digits and dashes; served at <code>/slug/</code>.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>title</legend>
        <input type="text" name="title" value="{{ title_value }}" maxlength="200" placeholder="optional label shown in this list">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>bundle (.zip)</legend>
        <input type="file" name="bundle" accept=".zip,application/zip">
        <p class="cms-help">a zip of HTML/CSS/JS/images; a single wrapping folder is unwrapped automatically. files over ~6 MB go through the chunked uploader (no size limit, progress shown below).</p>
      </fieldset>
      <p class="cms-actions">
        <button type="submit" class="cms-btn cms-btn-primary">create subpage</button>
      </p>
    </form>
  </section>
</article>
{% endblock %}
