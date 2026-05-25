{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-list-page">
  <header class="cms-edit-head">
    <h1>git repositories</h1>
    <p>create an empty bare repo, import an existing tree from a .zip, or set up a public http(s) mirror that the warmer pulls on a schedule. each repo is served read-only at <code>/git/&lt;slug&gt;/</code>.</p>
  </header>

{% if git_available %}{% else %}  <p class="cms-error">git backend not available: install <code>libgit2-dev</code> and <code>Git::Raw</code>, then restart the daemon.</p>
{% endif %}{% if error %}  <p class="cms-error">{{ error }}</p>
{% endif %}{% if repos %}  <table class="cms-table">
    <thead><tr><th>slug</th><th>title</th><th>owner</th><th>mirror</th><th>last pulled</th><th>head</th><th></th><th></th></tr></thead>
    <tbody>
{% for r in repos %}      <tr>
        <td><a href="/admin/git/{{ r.id }}/edit"><code>/git/{{ r.slug }}/</code></a></td>
        <td>{{ r.title }}</td>
        <td>{{ r.owner }}</td>
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
        <legend>import .zip (optional, ignored when a mirror url is set)</legend>
        <input type="file" name="bundle" accept=".zip,application/zip">
        <p class="cms-help">the bundle becomes the initial commit on the default branch.</p>
      </fieldset>
      <fieldset class="cms-field cms-field-text">
        <legend>or mirror from a public url</legend>
        <input type="text" name="mirror_url" value="{{ mirror_value }}" maxlength="500" placeholder="https://github.com/user/repo.git">
        <p class="cms-help">http(s) only in v1. the warmer fetches every <code>interval</code> seconds; first fetch happens within ~1 minute.</p>
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
