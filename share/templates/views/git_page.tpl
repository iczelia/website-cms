{% extends "layouts/git.tpl" %}

{% block head %}
<style>
/* Inline metadata + breadcrumb glue. The .qbtn-styled summary/log/
   tree tabs live in the right sidebar now (see layouts/git.tpl);
   everything below is per-page content chrome that sits in the main
   column. .ab-section / .ab-h1 / .ab-rule already come from
   about.compat.css. */
.git-meta, .git-sha { font-family: 'LM Mono', monospace;
                       font-size: 12px; color: #8aa0b8; }
.git-sha { color: #6ea4d6; }
.git-owner { margin: 0; color: #8aa0b8; font-size: 12px; }
.git-desc  { margin: 0 0 8px; color: #b9c8d6; }
.git-rawlink { font-size: 12px; }
.git-pager { font-size: 12px; }

/* Tables: listings, log, tree. Dark palette + dotted separators
   matching the rest of the site. */
table.git-listing, table.git-log, table.git-tree {
  border-collapse: collapse; width: 100%; font-size: 13px; }
.git-listing thead th, .git-log thead th, .git-tree thead th {
  text-align: left; padding: 4px 8px;
  border-bottom: 1px solid rgba(110,145,180,0.55);
  background: #0a1620; color: #b9c8d6;
  font-weight: bold; font-size: 12px; }
.git-listing tbody td, .git-log tbody td, .git-tree tbody td {
  padding: 4px 8px; border-bottom: 1px solid rgba(110,145,180,0.18);
  vertical-align: middle; }
.git-listing tbody tr:hover, .git-log tbody tr:hover,
.git-tree tbody tr:hover { background: rgba(140,180,220,0.08); }
td.size, td.mtime, th.size, th.mtime {
  text-align: right; white-space: nowrap; color: #8aa0b8; font-size: 12px; }
.git-tree td.icon, .git-tree th.icon { width: 30px; padding-right: 2px; }
.git-tree td.icon img { width: 22px; height: 22px; vertical-align: middle; }
.git-age { font-family: 'LM Mono', monospace; letter-spacing: 0; }

/* Branches / tags: table markup, laid out as floated fixed-width cells
   so IE9 / FF3.5 / Chrome 4 can still fit as many columns as the
   available width allows. */
.git-ref-table { display: block; width: 100%; border: 0; margin: 0 0 10px; overflow: hidden; }
.git-ref-table tbody {
  display: block;
}
.git-ref-table tr {
  display: block;
}
.git-ref-table tr:after {
  content: "";
  display: block;
  clear: both;
}
.git-ref-table td {
  display: block;
  float: left;
  width: 180px;
  padding: 2px 0;
  margin: 0 12px 2px 0;
  border: 0;
  word-break: break-word;
  word-wrap: break-word;
  overflow-wrap: anywhere;
}
.git-ref-time { color: #6e8aa8; font-size: 11px; white-space: nowrap; }
.git-ref-more {
  clear: both;
  margin: 0 0 10px;
  text-align: right;
  font-size: 12px;
}

/* README block. The Markup renderer's own h1/h2 take care of the
   internal structure; we only frame and lightly style. */
.git-readme { display: block; margin: 12px 0; padding: 12px 16px;
              background: #0a0e14;
              border: 1px solid rgba(110,145,180,0.35); }
.git-readme-name { font-family: 'LM Mono', monospace; font-size: 11px;
              color: #8aa0b8; margin: 0 0 8px; padding-bottom: 4px;
              border-bottom: 1px dashed rgba(110,145,180,0.35); }
.git-readme h1 { font-size: 24px; margin: 14px 0 8px;
  padding-bottom: 4px; border-bottom: 1px solid rgba(110,145,180,0.35);
  color: #b9c8d6; }
.git-readme h2 { font-size: 18px; margin: 12px 0 6px;
  padding-bottom: 4px; border-bottom: 1px solid rgba(110,145,180,0.35);
  color: #b9c8d6; }
.git-readme h3, .git-readme h4 { font-size: 14px; margin: 12px 0 6px;
  color: #b9c8d6; }
.git-readme p { margin: 6px 0; }
.git-readme ul, .git-readme ol { margin: 6px 0; padding-left: 24px; }
.git-readme code { background: rgba(110,145,180,0.18); padding: 1px 4px;
  font: 12px/1.4 'LM Mono', monospace; border-radius: 2px;
  color: #b8e0f4; }
.git-readme blockquote { margin: 6px 0; padding: 2px 12px;
  border-left: 3px solid rgba(110,145,180,0.55); color: #8aa0b8; }
.git-readme img { max-width: 100%; }
.git-readme table { border-collapse: collapse; margin: 8px 0; }
.git-readme th, .git-readme td {
  padding: 4px 8px; border: 1px solid rgba(110,145,180,0.35); }
.git-readme th { background: #0a1620; }

/* Commit body / diff frame. .hl + .hl-* tokens are already styled
   in about.compat.css so blob and commit views inherit the same
   syntax-highlighting look as fenced code in blog posts. */
.git-blob, .git-diff { margin: 8px 0; }
.git-diff .hl-add { color: #75c98a; font-style: normal; font-weight: normal; }
.git-diff .hl-del { color: #d06f73; font-style: normal; font-weight: normal; }

/* Line-numbered blob view. The handler turns the highlighter's
   <pre class="hl"><code>...</code></pre> into a <table class="git-lines">
   with one <tr id="L<n>"> per line. Clicking a number scrolls to and
   highlights that row (the :target pseudo-class). */
table.git-lines {
  /* The handler stitches "git-lines" with the highlighter's "hl
     lang-X" class list, so this element also matches the .hl block
     rule in about.compat.css (display: block; padding; etc.). The
     overrides below win because they're more specific. */
  display: table !important;
  border-collapse: collapse;
  width: 100%;
  padding: 0;
  background: #060912;
  border: 1px solid #2a3548;
  font: 13px/1.45 'LM Mono', monospace;
  color: #b9c8d6;
}
.git-lines td { vertical-align: top; padding: 0; }
.git-lines td.ln {
  width: 1%;
  padding: 0 12px 0 10px;
  text-align: right;
  border-right: 1px solid #2a3548;
  background: #050810;
  color: #6e8aa8;
  white-space: pre;
  -moz-user-select: none;
  -webkit-user-select: none;
  user-select: none;
}
.git-lines td.ln a { color: inherit; text-decoration: none; }
.git-lines td.ln a:hover { color: #b8e0f4; }
.git-lines td.lc {
  padding: 0 10px;
  white-space: pre;
  overflow-wrap: normal;
  word-break: normal;
}
.git-lines td.lc pre {
  margin: 0;
  padding: 0;
  border: 0;
  background: transparent;
  color: inherit;
  font: inherit;
  white-space: pre;
}
.git-lines tr:target { background: rgba(140,180,220,0.18); }
.git-lines tr:target td.ln { background: rgba(140,180,220,0.18); }

.git-body { padding: 6px 10px;
            white-space: pre-wrap;
            font: 12px/1.4 'LM Mono', monospace;
            color: #b9c8d6; }
.git-img { max-width: 100%;
           border: 1px solid rgba(110,145,180,0.35); }
.git-pdf { width: 100%; height: 80vh; min-height: 480px;
           border: 1px solid rgba(110,145,180,0.35); background: #fff; }
.binary, .empty { color: #8aa0b8; font-size: 13px; }

/* Tab-size preference toggle in the footer of each page. */
.git-prefs { margin: 12px 0; font-size: 11px; color: #8aa0b8;
             text-align: right; }
.git-prefs .tab a, .git-prefs .wrap a { color: #6ea4d6; margin-left: 6px; }
.git-prefs .tab a.on, .git-prefs .wrap a.on { color: #ffffff; font-weight: bold; }

{% if tab_size_css %}{{{ tab_size_css }}}{% endif %}
</style>
{% endblock %}

{% block content %}
{{{ git_content }}}
{% endblock %}
