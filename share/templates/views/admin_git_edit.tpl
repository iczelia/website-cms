{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>git: /git/{{ repo.slug }}/</h1>
    <p>
      <a href="/git/{{ repo.slug }}/" target="_blank" rel="noopener">open public view</a>
      &middot; head <code>{{ repo.head_short }}</code>
      &middot; last edit {{ repo.updated_fmt }}
    </p>
  </header>

{% if error %}  <p class="cms-error">{{ error }}</p>
{% endif %}{% if notice %}  <p class="cms-notice">{{ notice }}</p>
{% endif %}{% if git_available %}{% else %}  <p class="cms-error">git backend not available: install <code>libgit2-dev</code> and <code>Git::Raw</code>, then restart the daemon.</p>
{% endif %}

  <section class="cms-subpage-section">
    <h2>metadata</h2>
    <form class="cms-form" method="POST" action="/admin/git/{{ repo.id }}/meta">
      <input type="hidden" name="csrf" value="{{ csrf.meta }}">
      <fieldset class="cms-field cms-field-text">
        <legend>slug</legend>
        <input type="text" name="slug" value="{{ repo.slug }}" required pattern="[a-z0-9][a-z0-9-]*" maxlength="63">
        <p class="cms-help"><strong>changing this moves the repository.</strong> the on-disk bare clone is renamed and every existing link to <code>/git/{{ repo.slug }}/</code> starts returning 404. no redirect is left behind.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>title</legend>
        <input type="text" name="title" value="{{ repo.title }}" maxlength="200">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>owner</legend>
        <input type="text" name="owner" value="{{ repo.owner }}" maxlength="200">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>description</legend>
        <input type="text" name="description" value="{{ repo.description }}" maxlength="500">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>group</legend>
        <select name="group_id">
{% for o in group_options %}          <option value="{{ o.id }}"{% if o.selected %} selected{% endif %}>{{ o.name }}</option>
{% endfor %}        </select>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>default branch</legend>
        <input type="text" name="default_branch" value="{{ repo.default_branch }}" maxlength="120" pattern="[A-Za-z0-9._/-]+">
      </fieldset>
      <p class="cms-actions">
        <button type="submit" class="cms-btn cms-btn-primary">save</button>
      </p>
    </form>
  </section>

  <section class="cms-subpage-section">
    <h2>mirror</h2>
    <form class="cms-form" method="POST" action="/admin/git/{{ repo.id }}/mirror">
      <input type="hidden" name="csrf" value="{{ csrf.mirror }}">
      <fieldset class="cms-field cms-field-text">
        <legend>mirror url</legend>
        <input type="text" name="mirror_url" value="{{ repo.mirror_url }}" maxlength="500" placeholder="https://github.com/user/repo.git">
        <p class="cms-help">empty means no mirroring. http(s), <code>ssh://user@host/path</code> or <code>user@host:path</code>. ssh uses <code>git-ssh-key</code> from the daemon config with <code>BatchMode=yes</code>, so a key that needs a passphrase fails instead of hanging.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>interval (seconds)</legend>
        <input type="text" name="mirror_interval_s" value="{{ repo.mirror_interval_s }}" pattern="[0-9]+" maxlength="9">
      </fieldset>
      <p class="cms-actions">
        <button type="submit" class="cms-btn cms-btn-primary">save mirror</button>
      </p>
    </form>

    <p>
      <strong>last pull:</strong>
      {% if repo.pulled_fmt %}{{ repo.pulled_fmt }} [{{ repo.last_pull_status }}]{% else %}never{% endif %}
    </p>
{% if repo.last_pull_error %}    <pre class="cms-meta">{{ repo.last_pull_error }}</pre>
{% endif %}
    <form method="POST" action="/admin/git/{{ repo.id }}/pull-now" class="cms-inline-form">
      <input type="hidden" name="csrf" value="{{ csrf.pull }}">
      <button type="submit" class="cms-btn">pull now</button>
    </form>
  </section>

  <section class="cms-subpage-section">
    <h2>overlay .zip</h2>
    <form class="cms-form" method="POST" action="/admin/git/{{ repo.id }}/import-zip" enctype="multipart/form-data" data-cms-upload="bundle">
      <input type="hidden" name="csrf" value="{{ csrf.import }}">
      <fieldset class="cms-field cms-field-text">
        <legend>.zip bundle</legend>
        <input type="file" name="bundle" accept=".zip,application/zip">
        <p class="cms-help">creates a new commit on the default branch with the bundle's tree.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>author name</legend>
        <input type="text" name="author_name" value="iczelia" maxlength="200">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>author email</legend>
        <input type="text" name="author_email" value="" maxlength="200" placeholder="leave blank to use site.email">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>commit message</legend>
        <input type="text" name="commit_message" value="overlay import" maxlength="200">
      </fieldset>
      <p class="cms-actions">
        <button type="submit" class="cms-btn cms-btn-primary">import bundle</button>
      </p>
    </form>
  </section>

  <section class="cms-subpage-section">
    <h2>danger zone</h2>
    <form method="POST" action="/admin/git/{{ repo.id }}/delete" class="cms-inline-form">
      <input type="hidden" name="csrf" value="{{ csrf.del }}">
      <button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('delete repo /git/{{ repo.slug }}/ and its on-disk bare clone?')">delete repository</button>
    </form>
  </section>
</article>
{% endblock %}
