{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>media</h1>
    <p class="cms-help">drop / paste into the post editor to auto-upload, or pick a file:</p>
    <form class="cms-form" method="POST" action="/admin/media/upload" enctype="multipart/form-data">
      <input type="hidden" name="csrf" value="{{ csrf.upload }}">
      <p><input type="file" name="file" accept="image/*" required></p>
      <p><button type="submit" class="cms-btn cms-btn-primary">upload</button></p>
    </form>
  </header>

{% if items %}  <div class="cms-media-grid">
{% for m in items %}    <figure class="cms-media-tile">
      <a href="{{ m.url }}" target="_blank" rel="noopener"><img src="{{ m.thumb_url }}" alt="{{ m.orig_name }}"></a>
      <figcaption>
        <code class="cms-media-url">{{ m.url }}</code><br>
        <span class="cms-meta">{{ m.size_kb }} KB | {{ m.date_fmt }}</span><br>
        <form method="POST" action="/admin/media/{{ m.id }}/delete" class="cms-inline-form" onsubmit="return confirm('delete?')">
          <input type="hidden" name="csrf" value="{{ m.csrf_del }}">
          <button type="submit" class="cms-btn cms-btn-danger">delete</button>
        </form>
      </figcaption>
    </figure>
{% endfor %}  </div>
{% else %}  <p>no media yet.</p>
{% endif %}</article>
{% endblock %}
