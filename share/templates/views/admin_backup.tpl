{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>backup | export | import | wipe</h1>
    <p class="cms-meta">snapshots are <code>VACUUM INTO</code> SQLite files plus the <code>media/</code> directory, packaged in a tar archive. ephemeral tables (response_cache, tex_cache, sessions, login_throttle, guestbook_throttle) are excluded from the snapshot.</p>
  </header>

  <section class="cms-anal-block">
    <h2>export</h2>
    <p>download a complete snapshot you can restore on this or another instance.</p>
    <form class="cms-form" method="POST" action="/admin/backup/export">
      <input type="hidden" name="csrf" value="{{ csrf.export }}">
      <p><button type="submit" class="cms-btn cms-btn-primary">export now</button></p>
    </form>
  </section>

  <section class="cms-anal-block">
    <h2>import</h2>
    <p>upload a previously-exported tar archive. <strong>this overwrites the live DB and media directory</strong>; the previous DB is kept as <code>site.db.preimport</code>.</p>
    <form class="cms-form" method="POST" action="/admin/backup/import" enctype="multipart/form-data" data-cms-upload="archive">
      <input type="hidden" name="csrf" value="{{ csrf.import }}">
      <p><input type="file" name="archive" accept=".tar" required></p>
      <p class="cms-help">files over ~6 MB go through the chunked uploader (no size limit, progress shown below).</p>
      <p><button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('overwrite the live DB and media?')">import &amp; replace</button></p>
    </form>
  </section>

  <section class="cms-anal-block">
    <h2>wipe</h2>
    <p>drops every table (except your admin login) and reapplies the schema. <strong>this is irreversible.</strong></p>
    <p>quiesce traffic first; sibling workers writing during the wipe will hit table-not-found errors mid-request.</p>
    <form class="cms-form" method="POST" action="/admin/backup/wipe">
      <input type="hidden" name="csrf" value="{{ csrf.wipe }}">
      <p><label><input type="checkbox" name="confirm1" value="1" required> I understand this deletes all posts, pages, and media metadata.</label></p>
      <p><label><input type="checkbox" name="confirm2" value="1" required> I understand this deletes all analytics, revisions, and aliases.</label></p>
      <p><label><input type="checkbox" name="confirm3" value="1" required> I understand this is irreversible.</label></p>
      <p><label>type the phrase <code>WIPE THIS SITE</code>:<br>
        <input type="text" name="phrase" required pattern="WIPE THIS SITE" placeholder="WIPE THIS SITE"></label></p>
      <p><label>admin password (re-enter):<br>
        <input type="password" name="password" required></label></p>
      <p><button type="submit" class="cms-btn cms-btn-danger">wipe everything</button></p>
    </form>
  </section>
</article>
{% endblock %}
