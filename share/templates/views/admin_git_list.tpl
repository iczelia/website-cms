{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-list-page">
  <header class="cms-edit-head">
    <h1>git repositories</h1>
    <p>create an empty bare repo, import an existing tree from a .zip, or set up a mirror that the warmer pulls on a schedule. each repo is served read-only at <code>/git/&lt;slug&gt;/</code>.</p>
  </header>

{% if git_available %}{% else %}  <p class="cms-error">git backend not available: install <code>libgit2-dev</code> and <code>Git::Raw</code>, then restart the daemon.</p>
{% endif %}{% if error %}  <p class="cms-error">{{ error }}</p>
{% endif %}{% if notice %}  <p class="cms-notice">{{ notice }}</p>
{% endif %}{% if repos %}  <table class="cms-table">
    <thead><tr><th>slug</th><th>title</th><th>owner</th><th>group</th><th>mirror</th><th>last pulled</th><th>head</th><th></th><th></th></tr></thead>
    <tbody>
{% for r in repos %}      <tr>
        <td><a href="/admin/git/{{ r.id }}/edit"><code>/git/{{ r.slug }}/</code></a></td>
        <td>{{ r.title }}</td>
        <td>{{ r.owner }}</td>
        <td>{% if r.group_name %}{{ r.group_name }}{% else %}-{% endif %}</td>
        <td>{% if r.mirror_url %}<code>{{ r.mirror_url }}</code>{% else %}-{% endif %}</td>
        <td>{{ r.pulled_fmt }}{% if r.last_pull_status %} <span class="cms-meta">[{{ r.last_pull_status }}]</span>{% endif %}</td>
        <td><code>{{ r.head_short }}</code></td>
        <td><a href="{{ r.url }}" target="_blank" rel="noopener">open</a></td>
        <td>
          <form method="POST" action="/admin/git/{{ r.id }}/delete" class="cms-inline-form">
            <input type="hidden" name="csrf" value="{{ r.csrf_del }}">
            <button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('delete repo /git/{{ r.slug }}/ and its on-disk bare clone?')">delete</button>
          </form>
        </td>
      </tr>
{% endfor %}    </tbody>
  </table>
{% else %}  <p>no repositories yet.</p>
{% endif %}
  <section class="cms-subpage-section">
    <h2>groups</h2>
    <p class="cms-help">named sections on the public <code>/git/</code> index. lower <code>position</code> sorts first; ties break on name. ungrouped repositories are listed last.</p>
{% if groups %}    <table class="cms-table">
      <thead><tr><th>name</th><th>position</th><th>repos</th><th></th></tr></thead>
      <tbody>
{% for g in groups %}        <tr>
          <td colspan="3">
            <form method="POST" action="/admin/git/groups/{{ g.id }}/save" class="cms-inline-form">
              <input type="hidden" name="csrf" value="{{ g.csrf_save }}">
              <input type="text" name="name" value="{{ g.name }}" maxlength="120" required>
              <input type="text" name="position" value="{{ g.position }}" pattern="-?[0-9]+" maxlength="5" size="4">
              <span class="cms-meta">{{ g.repo_count }} repo(s)</span>
              <button type="submit" class="cms-btn">save</button>
            </form>
          </td>
          <td>
            <form method="POST" action="/admin/git/groups/{{ g.id }}/delete" class="cms-inline-form">
              <input type="hidden" name="csrf" value="{{ g.csrf_del }}">
              <button type="submit" class="cms-btn cms-btn-danger" onclick="return confirm('delete group {{ g.name }}? its repositories become ungrouped.')">delete</button>
            </form>
          </td>
        </tr>
{% endfor %}      </tbody>
    </table>
{% else %}    <p>no groups yet.</p>
{% endif %}
    <form class="cms-form" method="POST" action="/admin/git/groups/new">
      <input type="hidden" name="csrf" value="{{ csrf_group }}">
      <fieldset class="cms-field cms-field-text">
        <legend>new group</legend>
        <input type="text" name="name" maxlength="120" required placeholder="tools">
        <input type="text" name="position" value="0" pattern="-?[0-9]+" maxlength="5" size="4">
      </fieldset>
      <p class="cms-actions">
        <button type="submit" class="cms-btn cms-btn-primary">create group</button>
      </p>
    </form>
  </section>

  <section class="cms-subpage-section">
    <h2>new repository</h2>
    <form class="cms-form" method="POST" action="/admin/git/new" enctype="multipart/form-data" data-cms-upload="bundle">
      <input type="hidden" name="csrf" value="{{ csrf_form }}">
      <fieldset class="cms-field cms-field-text">
        <legend>slug</legend>
        <input type="text" name="slug" value="{{ slug_value }}" required pattern="[a-z0-9][a-z0-9-]*" maxlength="63" placeholder="my-project">
        <p class="cms-help">served under <code>/git/slug/</code>. lowercase letters, digits and dashes.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>title</legend>
        <input type="text" name="title" value="{{ title_value }}" maxlength="200">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>owner</legend>
        <input type="text" name="owner" value="{{ owner_value }}" maxlength="200">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>description</legend>
        <input type="text" name="description" value="{{ desc_value }}" maxlength="500">
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>group</legend>
        <select name="group_id">
{% for o in group_options %}          <option value="{{ o.id }}"{% if o.selected %} selected{% endif %}>{{ o.name }}</option>
{% endfor %}        </select>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>import .zip (optional, ignored when a mirror url is set)</legend>
        <input type="file" name="bundle" accept=".zip,application/zip">
        <p class="cms-help">the bundle becomes the initial commit on the default branch.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>or mirror from a url</legend>
        <input type="text" name="mirror_url" value="{{ mirror_value }}" maxlength="500" placeholder="https://github.com/user/repo.git">
        <p class="cms-help">http(s), <code>ssh://user@host/path</code> or <code>user@host:path</code>. the warmer fetches every <code>interval</code> seconds; first fetch happens within ~1 minute. ssh mirrors authenticate with <code>git-ssh-key</code> from the daemon config and never prompt.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>mirror interval (seconds)</legend>
        <input type="text" name="mirror_interval_s" value="{{ interval_value }}" pattern="[0-9]+" maxlength="9">
        <p class="cms-help">minimum 60. default 3600 (one hour).</p>
      </fieldset>
      <p class="cms-actions">
        <button type="submit" class="cms-btn cms-btn-primary">create repository</button>
      </p>
    </form>
  </section>
</article>
{% endblock %}
