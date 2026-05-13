<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }} :: admin</title>
<meta name="cms-upload-csrf" content="{{ csrf.upload }}">
<meta name="cms-preview-csrf" content="{{ csrf.preview }}">
<link rel="stylesheet" href="/cms.css">
<link rel="stylesheet" href="/vendor/codemirror/codemirror.min.css">
<link rel="stylesheet" href="/vendor/codemirror/eclipse.css">
{% block head %}{% endblock %}
</head>
<body class="cms-body">
<header class="cms-header">
  <div class="cms-brand"><a href="/admin/">iczelia.cms</a></div>
  <nav class="cms-nav">
    <a href="/admin/">dashboard</a>
    <a href="/admin/blog/">blog</a>
    <a href="/admin/journal/">journal</a>
    <a href="/admin/series/">series</a>
    <a href="/admin/updates/">updates</a>
    <a href="/admin/activity/">activity</a>
    <a href="/admin/webring/">webring</a>
    <a href="/admin/guestbook/">guestbook{% if pending_count %} ({{ pending_count }}){% endif %}</a>
    <a href="/admin/media/">media</a>
    <a href="/admin/pgp/">pgp</a>
    <a href="/admin/settings/">settings</a>
    <form class="cms-logout" method="POST" action="/admin/logout">
      <input type="hidden" name="csrf" value="{{ csrf.logout }}">
      <button type="submit">logout</button>
    </form>
  </nav>
</header>
<main class="cms-main">
{% if flash %}<div class="cms-flash cms-flash-{{ flash.kind }}">{{ flash.text }}</div>{% endif %}
{% block content %}{% endblock %}
</main>
<footer class="cms-footer">
  <span>iczelia.net cms · v{{ version }}</span>
</footer>
<script src="/vendor/codemirror/codemirror.min.js"></script>
<script src="/vendor/codemirror/markdown.min.js"></script>
<script src="/vendor/codemirror/stex.min.js"></script>
<script src="/vendor/codemirror/active-line.min.js"></script>
<script src="/vendor/marked.min.js"></script>
<script src="/cms.js"></script>
{% block scripts %}{% endblock %}
</body>
</html>
