<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }}</title>
{% include "partials/head-meta.tpl" %}
<link rel="stylesheet" href="/about.compat.css">
<link rel="icon" type="image/svg+xml" href="/assets-1024x768/favicon.svg">
<link rel="alternate icon" href="/favicon.ico">
<link rel="alternate" type="application/rss+xml"  title="iczelia RSS"  href="/index.xml">
<link rel="alternate" type="application/atom+xml" title="iczelia Atom" href="/feed.xml">
<link rel="preload" as="font" type="font/woff2" href="/fonts/arial.woff2" crossorigin>
<link rel="preload" as="font" type="font/woff2" href="/fonts/lmmono10-regular.woff2" crossorigin>
{% if chrome.theme_css %}<style>{{{ chrome.theme_css }}}</style>{% endif %}
<style>
/* Identical canvas width to the blog/about pages -- the bottom
   status-bar image is stitched at 900px (169 start + middle stretch
   + 78 end) and stretching it past that point makes the seam show.
   Wide content (code blocks, tables) scrolls inside its own frame
   instead. */

/* Sidebar: stack the lambda ABOVE the iczelia wordmark. */
body.git-body .ab-banner { text-align: center; line-height: 1.1; }
body.git-body .about-right .ab-lambda { display: block; margin: 0 auto; }
body.git-body .about-right .ab-title  { display: block; margin: 6px auto 0; }
body.git-body section > h1.ab-h1 { font-size: 30px; margin: 0 0 14px; }

/* Widen the canvas to 1200px on viewports that can fit it. Below
   1200px we fall back to the standard 900px chrome from
   about.compat.css so the bottom status-bar's stitched middle image
   doesn't stretch beyond its design width. The 1200px breakpoint is
   "I have enough screen for it" -- a 13" laptop at 1280x800 just
   clears, anything larger gets the extra room for log tables and
   tree views. */
@media (min-width: 1200px) {
  body.git-body .about-page { max-width: 1200px; }
  body.git-body .about-left {
    max-width: none;
    width: calc(100% - 252px);
  }
}

/* Tab list: reuse the existing .qbtn (Vixar / quicklink-btn
   background) but without the .nav-box 9-slice frame. Each link
   is a free-standing button, stacked vertically. .qbtn-on uses
   the same selected-background as the existing :hover state. */
.git-side-tabs { display: block; margin: 22px auto 0; text-align: center; }
.git-side-tabs .qbtn { margin: 0 auto; }
.git-side-tabs .qbtn + .qbtn { margin-top: 4px; }

/* Long branch / tag names + table cells: wrap inside the column
   rather than pushing it horizontally. */
.git-ref-table td, .git-ref-table a {
  word-break: break-all; word-wrap: break-word; overflow-wrap: anywhere; }
.git-listing td, .git-log td, .git-tree td,
.git-listing th, .git-log th, .git-tree th {
  word-break: break-word; word-wrap: break-word; overflow-wrap: anywhere; }
/* Code / diff: scroll horizontally inside the frame, don't push
   the column wider than .about-left. */
.git-blob, .git-diff, .git-body { max-width: 100%; overflow-x: auto; }
.hl { max-width: 100%; }
</style>
{% block head %}{% endblock %}
</head>
<body class="git-body">
<div class="about-page">

  <div class="about-left">
    {% block content %}{% endblock %}
  </div>

  <div class="about-right">
    <div class="ab-banner">
      <a class="ab-banner-link" href="/" aria-label="home">
        <img class="ab-lambda" src="/assets-1024x768/iczelia-128.png" alt="">
        <img class="ab-title"  src="/assets-1024x768/title.gif" alt="iczelia">
      </a>
    </div>

{% if git_repo_slug %}    <nav class="git-side-tabs" aria-label="git repo tabs">
      <a class="qbtn" href="/git/">/git/</a><a class="qbtn{% if tab_summary_on %} qbtn-on{% endif %}" href="/git/{{ git_repo_slug }}/">summary</a><a class="qbtn{% if tab_log_on %} qbtn-on{% endif %}"     href="/git/{{ git_repo_slug }}/log/">log</a><a class="qbtn{% if tab_tree_on %} qbtn-on{% endif %}"    href="/git/{{ git_repo_slug }}/tree/">tree</a>
    </nav>
{% else %}    <nav class="git-side-tabs" aria-label="git nav">
      <a class="qbtn qbtn-on" href="/git/">/git/</a>
    </nav>
{% endif %}

    <img class="ab-vert" src="/assets-about/vert.jpg" alt="">
  </div>

{% include "partials/about-footer.tpl" %}

</div>
</body>
</html>
