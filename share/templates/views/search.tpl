{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: search ::</h1>
      <form class="ab-search" method="GET" action="/search/">
        <input type="search" name="q" value="{{ q }}" maxlength="100" placeholder="search posts" autofocus>
        <button type="submit">go</button>
      </form>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
{% if empty_query %}      <p>type a query above to search the blog and journal.</p>
{% else %}{% if results %}      <p class="ab-search-summary">{{ count(results) }} results for &ldquo;{{ q }}&rdquo;</p>
      <ul class="ab-list-posts">
{% for r in results %}        <li>
          <a class="ab-search-title" href="{{ r.url }}">{{ r.title }}</a>
          <span class="ab-search-kind">[{{ r.kind }}]</span>
          <p class="ab-search-snippet">{{{ r.sn }}}</p>
        </li>
{% endfor %}      </ul>
{% else %}      <p>no results for &ldquo;{{ q }}&rdquo;.</p>
{% endif %}{% endif %}    </section>
{% endblock %}
