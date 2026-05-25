{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit cms-subpage-edit" id="cms-subpages" data-id="{{ sp.id }}" data-csrf="{{ csrf.file }}" data-dir="{{ dir }}">
  <header class="cms-edit-head">
    <h1>subpage: <code>/{{ sp.slug }}/</code></h1>
    <p class="cms-meta"><a href="{{ dir_url }}" target="_blank" rel="noopener">open {{ dir_url }} &raquo;</a> &middot; <a href="/admin/subpages/">all subpages</a> &middot; {{ file_count }} files in this bundle</p>
{% if error %}    <p class="cms-error">{{ error }}</p>
{% endif %}{% if notice %}    <p class="cms-subpage-notice">{{ notice }}</p>
{% endif %}{% if no_index %}    <p class="cms-error">this bundle has no <code>index.html</code>; the subpage root will return 404 until you add one.</p>
{% endif %}  </header>

{% if is_root %}  <form class="cms-form" method="POST" action="/admin/subpages/{{ sp.id }}/meta">
    <input type="hidden" name="csrf" value="{{ csrf.meta }}">
    <fieldset class="cms-field cms-field-text">
      <legend>slug</legend>
      <input type="text" name="slug" value="{{ sp.slug }}" required pattern="[a-z0-9][a-z0-9-]*" maxlength="63">
    </fieldset>
    <fieldset class="cms-field cms-field-text">
      <legend>title</legend>
      <input type="text" name="title" value="{{ sp.title }}" maxlength="200">
    </fieldset>
    <fieldset class="cms-field cms-field-text">
      <legend>directory listing</legend>
      <label class="cms-subpage-check"><input type="checkbox" name="listing" value="1"{% if sp.listing %} checked{% endif %}> generate an Apache-style index for directories that have no <code>index.html</code></label>
      <p class="cms-help">if <code>README</code> (or <code>README.md</code>/<code>.txt</code>/<code>.rst</code>) is present, it is shown as a code block above the listing.</p>
    </fieldset>
    <p class="cms-actions"><button type="submit" class="cms-btn cms-btn-primary">save details</button></p>
  </form>
{% endif %}
  <section class="cms-subpage-section">
    <h2>Index of <span class="cms-subpage-crumbs">{% for c in crumbs %}{% if c.current %}<span>{{ c.label }}</span>{% else %}<a href="{{ c.href }}">{{ c.label }}</a>{% endif %}{% endfor %}</span></h2>

{% if readme %}    <section class="cms-subpage-readme"><h3>{{ readme.name }}</h3><pre><code>{{ readme.content }}</code></pre></section>
{% endif %}    <table class="cms-table cms-subpage-files cms-subpage-listing">
      <thead><tr><th></th><th>Name</th><th class="mtime">Last modified</th><th class="size">Size</th><th></th></tr></thead>
      <tbody>
{% for r in rows %}        <tr{% if r.is_file %} data-path="{{ r.path }}" data-editable="{{ r.editable }}"{% endif %}>
          <td class="icon"><img src="/cms-icons/{{ r.icon }}" alt=""></td>
          <td class="name">{% if r.is_dir %}<a href="{{ r.href }}">{{ r.name }}</a>{% endif %}{% if r.is_file %}<a href="{{ r.public_url }}" target="_blank" rel="noopener"><code>{{ r.name }}</code></a>{% endif %}</td>
          <td class="mtime">{{ r.mtime }}</td>
          <td class="size">{{ r.size }}</td>
          <td class="cms-subpage-fileactions">
{% if r.is_file %}{% if r.editable %}            <button type="button" class="cms-btn cms-btn-tiny js-edit">edit</button>
{% endif %}            <a class="cms-btn cms-btn-tiny" href="{{ r.view_url }}" target="_blank" rel="noopener">view</a>
            <form method="POST" action="/admin/subpages/{{ sp.id }}/file/delete" class="cms-inline-form">
              <input type="hidden" name="csrf" value="{{ csrf.file }}">
              <input type="hidden" name="path" value="{{ r.path }}">
              <input type="hidden" name="dir" value="{{ dir }}">
              <button type="submit" class="cms-btn cms-btn-tiny cms-btn-danger" onclick="return confirm('delete {{ r.path }}?')">del</button>
            </form>
{% endif %}          </td>
        </tr>
{% endfor %}      </tbody>
    </table>
{% if empty %}    <p class="cms-help">this directory is empty.</p>
{% endif %}  </section>

  <section class="cms-subpage-section cms-subpage-editor">
    <h2>editor</h2>
    <p class="cms-help">pick a text file above, or type a new path to create one. binary files (images, fonts) are managed through upload below.</p>
    <p class="cms-subpage-editbar">
      <input type="text" id="cms-subpage-path" placeholder="path, e.g. {{ new_file_path_hint }}index.html" value="{{ new_file_path_hint }}">
      <button type="button" class="cms-btn cms-btn-primary" id="cms-subpage-save">save file</button>
      <button type="button" class="cms-btn cms-btn-cancel" id="cms-subpage-newfile" data-prefix="{{ new_file_path_hint }}">new file</button>
      <span class="cms-subpage-status" id="cms-subpage-status"></span>
    </p>
    <textarea id="cms-subpage-content" class="cms-subpage-textarea" spellcheck="false"></textarea>
  </section>

  <section class="cms-subpage-section">
    <h2>upload a file to <code>{{ dir_url }}</code></h2>
    <form class="cms-form" method="POST" action="/admin/subpages/{{ sp.id }}/file/upload" enctype="multipart/form-data">
      <input type="hidden" name="csrf" value="{{ csrf.file }}">
      <input type="hidden" name="dir" value="{{ dir }}">
      <fieldset class="cms-field cms-field-text">
        <legend>file</legend>
        <input type="file" name="file" required>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>path (optional)</legend>
        <input type="text" name="path" maxlength="255" placeholder="defaults to the uploaded file name">
        <p class="cms-help">leave blank to drop the file into this directory; a path with slashes is taken relative to the bundle root and overrides the directory.</p>
      </fieldset>
      <p class="cms-actions"><button type="submit" class="cms-btn cms-btn-primary">upload file</button></p>
    </form>
  </section>

{% if is_root %}  <section class="cms-subpage-section">
    <h2>replace bundle</h2>
    <form class="cms-form" method="POST" action="/admin/subpages/{{ sp.id }}/rezip" enctype="multipart/form-data" data-cms-upload="bundle">
      <input type="hidden" name="csrf" value="{{ csrf.rezip }}">
      <fieldset class="cms-field cms-field-text">
        <legend>bundle (.zip)</legend>
        <input type="file" name="bundle" accept=".zip,application/zip">
        <p class="cms-help">replaces every file in this subpage with the contents of the new zip. files over ~6 MB go through the chunked uploader (no size limit, progress shown below).</p>
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
{% endif %}</article>
{% endblock %}
{% block scripts %}<script src="/cms-subpages.js"></script>
{% endblock %}
