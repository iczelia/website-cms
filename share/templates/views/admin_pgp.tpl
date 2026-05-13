{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{{ title }}</h1>
  </header>

  <p>The key uploaded here is served at <code>/pub.pgp</code> with content-type <code>application/pgp-keys</code>.</p>
  {% if has_key %}
    <p>Currently installed: {{ key_size }} bytes, uploaded {{ key_uploaded_fmt }}.</p>
  {% endif %}
  {% if has_key %}{% else %}
    <p>No key installed. <code>/pub.pgp</code> currently 404s.</p>
  {% endif %}

  <form class="cms-form" method="POST" action="/admin/pgp/" enctype="multipart/form-data">
    <input type="hidden" name="csrf" value="{{ csrf_upload }}">
    <p><label>Upload a new key (.pgp / .asc / armored text)<br>
      <input type="file" name="file" accept=".pgp,.asc,application/pgp-keys,text/plain" required>
    </label></p>
    <p class="cms-actions"><button type="submit" class="cms-btn cms-btn-primary">upload</button></p>
  </form>

  {% if has_key %}
    <form class="cms-form" method="POST" action="/admin/pgp/delete" onsubmit="return confirm('remove the installed PGP key?')">
      <input type="hidden" name="csrf" value="{{ csrf_delete }}">
      <p class="cms-actions"><button type="submit" class="cms-btn cms-btn-danger">remove key</button></p>
    </form>
  {% endif %}
</article>
{% endblock %}
