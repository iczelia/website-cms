{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-edit">
  <header class="cms-edit-head">
    <h1>{% if row %}edit language{% else %}new language{% endif %}</h1>
    {% if error %}<p class="cms-error">{{ error }}</p>{% endif %}
    <p class="cms-meta">paste word lists; the engine builds <code>\b(?:word1|word2|...)\b</code> rules. metachars are quotemeta'd; admin can never inject regex syntax.</p>
  </header>

  <form class="cms-form" method="POST" action="{{ form_action }}">
    <input type="hidden" name="csrf" value="{{ csrf_form }}">

    <fieldset class="cms-field cms-field-text">
      <legend>name</legend>
      <input type="text" name="name" value="{{ rec.name }}" required pattern="[a-z][a-z0-9+_:-]{0,40}" maxlength="40">
      <p class="cms-help">canonical lowercase name. e.g. <code>kotlin</code>.</p>
    </fieldset>

    <fieldset class="cms-field cms-field-text">
      <legend>aliases</legend>
      <input type="text" name="aliases" value="{{ rec.aliases }}" maxlength="200">
      <p class="cms-help">comma-separated.</p>
    </fieldset>

    <fieldset class="cms-field cms-field-markdown">
      <legend>keywords</legend>
      <textarea name="keywords" rows="4">{{ rec.keywords }}</textarea>
      <p class="cms-help">comma- or whitespace-separated. each token: <code>[A-Za-z_][\w:-]{0,63}</code>.</p>
    </fieldset>

    <fieldset class="cms-field cms-field-markdown">
      <legend>types</legend>
      <textarea name="types" rows="3">{{ rec.types }}</textarea>
    </fieldset>

    <fieldset class="cms-field cms-field-markdown">
      <legend>builtins / constants</legend>
      <textarea name="builtins" rows="3">{{ rec.builtins }}</textarea>
    </fieldset>

    <fieldset class="cms-field cms-field-text">
      <legend>line comment</legend>
      <input type="text" name="line_comment" value="{{ rec.line_comment }}" maxlength="3">
      <p class="cms-help">e.g. <code>//</code> or <code>#</code>.</p>
    </fieldset>

    <fieldset class="cms-field cms-field-text">
      <legend>block comment</legend>
      <input type="text" name="block_comment" value="{{ rec.block_comment }}" maxlength="8">
      <p class="cms-help">space-separated open/close. e.g. <code>/* */</code>.</p>
    </fieldset>

    <fieldset class="cms-field cms-field-text">
      <legend>string quotes</legend>
      <input type="text" name="string_quotes" value="{{ rec.string_quotes }}" maxlength="4">
      <p class="cms-help">each char gets a string rule. e.g. <code>"'</code>.</p>
    </fieldset>

    <p class="cms-actions">
      <button type="submit" class="cms-btn cms-btn-primary">save</button>
      <a class="cms-btn cms-btn-cancel" href="/admin/highlight/">cancel</a>
{% if row %}      <button type="submit" formaction="/admin/highlight/{{ row.id }}/delete" formmethod="POST" class="cms-btn cms-btn-danger" onclick="return confirm('delete this language?')">delete</button>
{% endif %}    </p>
  </form>
</article>
{% endblock %}
