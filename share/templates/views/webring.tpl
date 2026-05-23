{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: webring ::</h1>
      {{{ data.intro_html }}}
    </section>

    <div class="ab-rule"></div>

{% for s in ring_sections %}    <section class="ab-section">
      <h2 class="ab-h2">>> {{ s.label }}</h2>
{% if s.is_more %}      <div class="ab-ring-buttons">
{% for m in s.members %}{% if m.url %}        <a href="{{ m.url }}" rel="noopener" title="{{ m.name }}"><img src="{{ m.image_url }}" alt="{{ m.name }}" width="88" height="31"></a>
{% else %}        <img src="{{ m.image_url }}" alt="{{ m.name }}" title="{{ m.name }}" width="88" height="31">
{% endif %}{% endfor %}      </div>
{% else %}      <ul class="ab-ring">
{% for m in s.members %}        <li class="ab-ring-item">
{% if m.url %}          <a class="ab-ring-link" href="{{ m.url }}" rel="noopener">
{% if m.image_url %}            <img class="ab-ring-img" src="{{ m.image_url }}" alt="{{ m.name }}" width="88" height="31">
{% else %}            <span class="ab-ring-fallback">{{ m.name }}</span>
{% endif %}            <span class="ab-ring-meta">
              <span class="ab-ring-name">{{ m.name }}</span>
{% if m.domain %}              <span class="ab-ring-domain">{{ m.domain }}</span>
{% endif %}            </span>
          </a>
{% else %}{% if m.image_url %}          <span class="ab-ring-link ab-ring-static">
            <img class="ab-ring-img" src="{{ m.image_url }}" alt="{{ m.name }}" width="88" height="31">
            <span class="ab-ring-meta">
              <span class="ab-ring-name">{{ m.name }}</span>
            </span>
          </span>
{% endif %}{% endif %}        </li>
{% endfor %}      </ul>
{% endif %}    </section>
    <div class="ab-rule"></div>
{% endfor %}    <section class="ab-section">
      <p><small>Bottom line: links &ne; endorsements.</small></p>
    </section>
{% endblock %}
