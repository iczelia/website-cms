<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }}</title>
<link rel="stylesheet" href="/about.compat.css">
<link rel="icon" type="image/svg+xml" href="/assets-1024x768/favicon.svg">
<link rel="alternate icon" href="/favicon.ico">
<link rel="alternate" type="application/rss+xml"  title="iczelia RSS"  href="/index.xml">
<link rel="alternate" type="application/atom+xml" title="iczelia Atom" href="/feed.xml">
<link rel="preload" as="font" type="font/woff" href="/fonts/arial.woff" crossorigin>
<link rel="preload" as="font" type="font/woff" href="/fonts/lmmono10-regular.woff" crossorigin>
{% if chrome.theme_css %}<style>{{{ chrome.theme_css }}}</style>{% endif %}
{% block head %}{% endblock %}
</head>
<body>
<div class="about-page">

  <div class="about-left">
    {% block content %}{% endblock %}
  </div>

  <div class="about-right">
    <div class="ab-banner">
      <a class="ab-banner-link" href="/" aria-label="home">
        <img class="ab-title"  src="/assets-1024x768/title.gif" alt="iczelia">
        <img class="ab-lambda" src="/assets-1024x768/iczelia-128.png" alt="">
      </a>
    </div>

{% include "partials/nav.tpl" %}

    <img class="ab-vert" src="/assets-about/vert.jpg" alt="">
  </div>

{% include "partials/about-footer.tpl" %}

</div>
</body>
</html>
