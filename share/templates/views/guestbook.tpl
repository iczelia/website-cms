{% extends "layouts/page.tpl" %}

{% block content %}
    <section class="ab-section">
      <h1 class="ab-h1">:: guestbook ::</h1>
      {{{ data.intro_html }}}
    </section>

{% if submitted %}
    <div class="ab-rule"></div>
    <section class="ab-section">
      <p class="ab-flash">thank you. your entry is awaiting moderation.</p>
    </section>
{% endif %}

{% if rate_limited %}
    <div class="ab-rule"></div>
    <section class="ab-section">
      <p class="ab-flash ab-flash-err">you're posting too quickly. please wait and try again.</p>
    </section>
{% endif %}

{% if error %}
    <div class="ab-rule"></div>
    <section class="ab-section">
      <p class="ab-flash ab-flash-err">{{ error }}</p>
    </section>
{% endif %}

    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; sign the book</h2>
      <form class="gb-form" method="POST" action="/guestbook/">
        <input type="hidden" name="csrf" value="{{ csrf }}">
        <input class="gb-honeypot" type="text" name="website" value="" tabindex="-1" autocomplete="off">
        <p><label>nickname<br><input type="text" name="nickname" maxlength="40" required></label></p>
        <p><label>message<br><textarea name="body" rows="6" maxlength="4000" required></textarea></label></p>
        <p><button type="submit">post</button></p>
      </form>
    </section>

    <div class="ab-rule"></div>

    <section class="ab-section">
      <h2 class="ab-h2">&raquo; entries</h2>
{% if entries %}{% for e in entries %}      <article class="gb-entry">
        <div class="gb-meta"><span class="gb-from">from <strong>{{ e.nickname }}</strong></span> <span class="gb-date">{{ e.date_fmt }}</span></div>
        <div class="gb-body">{{{ e.body_html }}}</div>
{% if e.reply %}        <div class="gb-reply">
          <div class="gb-meta">&#x21B3; reply from <strong>iczelia</strong> <span class="gb-date">{{ e.reply.date_fmt }}</span></div>
          <div class="gb-body">{{{ e.reply.body_html }}}</div>
        </div>
{% endif %}      </article>
{% endfor %}{% else %}      <p>no entries yet. be the first.</p>
{% endif %}    </section>
{% endblock %}
