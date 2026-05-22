{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit cms-subpage-edit" id="cms-subpages" data-id="{{ sp.id }}" data-csrf="{{ csrf.file }}">
  <header class="cms-edit-head">
    <h1>subpage: <code>/{{ sp.slug }}/</code></h1>
    <p class="cms-meta"><a href="{{ sp_url }}" target="_blank" rel="noopener">open {{ sp_url }} &raquo;</a> &middot; <a href="/admin/subpages/">all subpages</a></p>
{% if error %}    <p class="cms-error">{{ error }}</p>
{% endif %}{% if notice %}    <p class="cms-subpage-notice">{{ notice }}</p>
{% endif %}{% if no_index %}    <p class="cms-error">this bundle has no <code>index.html</code>; the subpage root will return 404 until you add one.</p>
{% endif %}  </header>

  <form class="cms-form" method="POST" action="/admin/subpages/{{ sp.id }}/meta">
    <input type="hidden" name="csrf" value="{{ csrf.meta }}">
    <fieldset class="cms-field cms-field-text">
      <legend>slug</legend>
      <input type="text" name="slug" value="{{ sp.slug }}" required pattern="[a-z0-9][a-z0-9-]*" maxlength="63">
    </fieldset>
    <fieldset class="cms-field cms-field-text">
      <legend>title</legend>
      <input type="text" name="title" value="{{ sp.title }}" maxlength="200">
    </fieldset>
    <p class="cms-actions"><button type="submit" class="cms-btn cms-btn-primary">save details</button></p>
  </form>

  <section class="cms-subpage-section">
    <h2>files ({{ file_count }})</h2>
{% if files %}    <table class="cms-table cms-subpage-files">
      <thead><tr><th>path</th><th>type</th><th>size</th><th></th></tr></thead>
      <tbody>
{% for f in files %}        <tr data-path="{{ f.path }}" data-editable="{{ f.editable }}">
          <td><code>{{ f.path }}</code></td>
          <td>{{ f.content_type }}</td>
          <td>{{ f.size_fmt }}</td>
          <td class="cms-subpage-fileactions">
{% if f.editable %}            <button type="button" class="cms-btn cms-btn-tiny js-edit">edit</button>
{% endif %}            <a class="cms-btn cms-btn-tiny" href="/admin/subpages/{{ sp.id }}/file?path={{ urlencode(f.path) }}" target="_blank" rel="noopener">view</a>
            <form method="POST" action="/admin/subpages/{{ sp.id }}/file/delete" class="cms-inline-form">
              <input type="hidden" name="csrf" value="{{ csrf.file }}">
              <input type="hidden" name="path" value="{{ f.path }}">
              <button type="submit" class="cms-btn cms-btn-tiny cms-btn-danger" onclick="return confirm('delete {{ f.path }}?')">del</button>
            </form>
          </td>
        </tr>
{% endfor %}      </tbody>
    </table>
{% else %}    <p>this bundle is empty; upload a file or replace the bundle below.</p>
{% endif %}  </section>

  <section class="cms-subpage-section cms-subpage-editor">
    <h2>editor</h2>
    <p class="cms-help">pick a text file above, or type a new path to create one. binary files (images, fonts) are managed through upload below.</p>
    <p class="cms-subpage-editbar">
      <input type="text" id="cms-subpage-path" placeholder="path, e.g. index.html or css/style.css">
      <button type="button" class="cms-btn cms-btn-primary" id="cms-subpage-save">save file</button>
      <button type="button" class="cms-btn cms-btn-cancel" id="cms-subpage-newfile">new file</button>
      <span class="cms-subpage-status" id="cms-subpage-status"></span>
    </p>
    <textarea id="cms-subpage-content" class="cms-subpage-textarea" spellcheck="false"></textarea>
  </section>

  <section class="cms-subpage-section">
    <h2>upload a file</h2>
    <form class="cms-form" method="POST" action="/admin/subpages/{{ sp.id }}/file/upload" enctype="multipart/form-data">
      <input type="hidden" name="csrf" value="{{ csrf.file }}">
      <fieldset class="cms-field cms-field-text">
        <legend>file</legend>
        <input type="file" name="file" required>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>path (optional)</legend>
        <input type="text" name="path" maxlength="255" placeholder="defaults to the uploaded file name">
        <p class="cms-help">use this to place the file in a subfolder, e.g. <code>img/logo.png</code>; an existing file at the same path is replaced.</p>
      </fieldset>
      <p class="cms-actions"><button type="submit" class="cms-btn cms-btn-primary">upload file</button></p>
    </form>
  </section>

  <section class="cms-subpage-section">
    <h2>replace bundle</h2>
    <form class="cms-form" method="POST" action="/admin/subpages/{{ sp.id }}/rezip" enctype="multipart/form-data">
      <input type="hidden" name="csrf" value="{{ csrf.rezip }}">
      <fieldset class="cms-field cms-field-text">
        <legend>bundle (.zip)</legend>
        <input type="file" name="bundle" accept=".zip,application/zip">
        <p class="cms-help">replaces every file in this subpage with the contents of the new zip.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>or import from a server path</legend>
        <input type="text" name="zip_path" maxlength="1024" placeholder="/var/lib/iczelia/bundles/site.zip">
        <p class="cms-help">absolute path to a .zip on the server. no size limit; use this for bundles too large to upload.</p>
      </fieldset>
      <p class="cms-actions"><button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('replace all files in this subpage?')">replace bundle</button></p>
    </form>
  </section>

  <section class="cms-subpage-section">
    <h2>delete subpage</h2>
    <form method="POST" action="/admin/subpages/{{ sp.id }}/delete">
      <input type="hidden" name="csrf" value="{{ csrf.del }}">
      <button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('delete subpage /{{ sp.slug }}/ and all files?')">delete this subpage</button>
    </form>
  </section>
</article>
{% endblock %}
{% block scripts %}<script src="/cms-subpages.js"></script>
{% endblock %}
