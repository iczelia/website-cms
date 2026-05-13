<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }}</title>
{% include "partials/head-meta.tpl" %}
<style>{{{ home_css.common }}}</style>
<!-- Ranges overlap 1px at each boundary so no viewport matches nothing. -->
<style media="(max-height: 600px)">{{{ home_css.s600 }}}</style>
<style media="(min-width: 600px) and (max-width: 900px)">{{{ home_css.s600 }}}</style>
<style media="(max-width: 600px) and (min-height: 600px)">{{{ home_css.mobile }}}</style>
<style media="(min-width: 900px) and (min-height: 600px) and (max-width: 1200px)">{{{ home_css.s800 }}}</style>
<style media="(min-width: 900px) and (min-height: 600px) and (max-height: 800px)">{{{ home_css.s800 }}}</style>
<style media="(min-width: 1200px) and (min-height: 800px)">{{{ home_css.s1024 }}}</style>
<link rel="icon" type="image/svg+xml" href="/assets-1024x768/favicon.svg">
<link rel="alternate icon" href="/favicon.ico">
<link rel="alternate" type="application/rss+xml"  title="iczelia RSS"  href="/index.xml">
<link rel="alternate" type="application/atom+xml" title="iczelia Atom" href="/feed.xml">
</head>
<body>
<div class="page">
  <div class="hero-bg"></div>
  <div class="frame">
    <div class="tl"></div><div class="tm"></div><div class="tr"></div>
    <div class="ml"></div><div></div><div class="mr"></div>
    <div class="bl"></div><div class="bm"></div><div class="br"></div>
  </div>
  <div class="title" role="img" aria-label="iczelia"></div>
  <nav class="nav-box">
    <div class="qb tl"></div><div class="qb tm"></div><div class="qb tr"></div>
    <div class="qb ml"></div><div class="qb mm"></div><div class="qb mr"></div>
    <div class="qb bl"></div><div class="qb bm"></div><div class="qb br"></div>
    <div class="qb-content">
      <a class="qbtn" href="/about/">about</a>
      <a class="qbtn" href="/cv/">cv</a>
      <a class="qbtn" href="/journal/">journal</a>
      <a class="qbtn" href="/blog/">blog</a>
      <a class="qbtn" href="/guestbook/">guestbook</a>
      <a class="qbtn" href="/webring/">webring</a>
    </div>
  </nav>
  <aside class="pfp-frame profile-win">
    <div class="pf tl"></div><div class="pf tm"></div><div class="pf tr"></div>
    <div class="pf ml"></div>
    <div class="pfp-body">
      <div class="pfp-content">{{{ data.profile_html }}}</div>
    </div>
    <div class="pf mr"></div>
    <div class="pf bl"></div><div class="pf bm"></div><div class="pf br"></div>
    <div class="pfp-head">profile</div>
  </aside>
  <aside class="gw-frame updates">
    <div class="gw tl"></div><div class="gw tm"></div><div class="gw tr"></div>
    <div class="gw ml"></div>
    <div class="gw-body">
{% for u in updates %}      <div class="upd-item{% if u.mid %} upd-mid{% endif %}{% if u.extra %} upd-extra{% endif %}">
        <div class="upd-date">&raquo; {{ u.date_fmt }}</div>
        <div class="upd-text">{{{ u.body_html }}}</div>
      </div>
{% if u.sep_after %}      <div class="upd-sep{% if u.sep_mid %} upd-mid{% endif %}{% if u.sep_extra %} upd-extra{% endif %}"></div>
{% endif %}{% endfor %}      <a class="upd-more" href="/updates/">&gt; view all updates</a>
    </div>
    <div class="gw mr"></div>
    <div class="gw bl"></div><div class="gw bm"></div><div class="gw br"></div>
    <div class="gw-head">:: updates ::</div>
  </aside>
  <aside class="gw-frame activity">
    <div class="gw tl"></div><div class="gw tm"></div><div class="gw tr"></div>
    <div class="gw ml"></div>
    <div class="gw-body">
      <div class="act-section act-full">
        <div class="act-section-title">github</div>
        <table class="act-table">
{% for a in activity.github %}          <tr><td class="act-line">{% if a.url %}<a href="{{ a.url }}">{{ a.prefix }}<span class="gh-user">{{ a.user }}</span><span class="gh-repo">{{ a.repo }}</span>{{ a.suffix }}</a>{% else %}{{ a.prefix }}<span class="gh-user">{{ a.user }}</span><span class="gh-repo">{{ a.repo }}</span>{{ a.suffix }}{% endif %}</td><td class="act-date">{{ a.ago }}</td></tr>
{% endfor %}        </table>
      </div>
      <div class="act-rule act-full"></div>
      <div class="act-section act-full">
        <table class="act-table">
{% for a in activity.mastodon %}          <tr><td><span class="act-section-title act-inline">mastodon</span> {% if a.url %}<a href="{{ a.url }}">{{ a.text }}</a>{% else %}{{ a.text }}{% endif %}</td><td class="act-date">{{ a.ago }}</td></tr>
{% endfor %}{% for a in activity.bluesky %}          <tr><td><span class="act-section-title act-inline">bluesky</span> {% if a.url %}<a href="{{ a.url }}">{{ a.text }}</a>{% else %}{{ a.text }}{% endif %}</td><td class="act-date">{{ a.ago }}</td></tr>
{% endfor %}        </table>
      </div>
      <div class="act-rule act-full"></div>
      <div class="act-section act-full">
        <div class="act-section-title">currently</div>
        <div class="act-line">{{ data.currently }}</div>
      </div>
      <div class="act-section act-compact">
        <table class="act-table">
{% for a in activity.github_compact %}          <tr><td><span class="act-section-title act-inline">github</span> last activity</td><td class="act-date">{{ a.ago }}</td></tr>
{% endfor %}        </table>
      </div>
      <div class="act-rule act-compact"></div>
      <div class="act-section act-compact">
        <table class="act-table">
{% for a in activity.mastodon %}          <tr><td><span class="act-section-title act-inline">mastodon</span> last post</td><td class="act-date">{{ a.ago }}</td></tr>
{% endfor %}{% for a in activity.bluesky %}          <tr><td><span class="act-section-title act-inline">bluesky</span> last post</td><td class="act-date">{{ a.ago }}</td></tr>
{% endfor %}        </table>
      </div>
      <div class="act-rule act-compact"></div>
      <div class="act-section act-compact">
        <div class="act-section-title">currently</div>
        <div class="act-line">{{ data.currently }}</div>
      </div>
    </div>
    <div class="gw mr"></div>
    <div class="gw bl"></div><div class="gw bm"></div><div class="gw br"></div>
    <div class="gw-head">:: recent activity ::</div>
  </aside>
  <aside class="bp-frame webring-win">
    <div class="bp-left"><a class="webring-link" href="/webring/"><span class="wr-glyphs">{ &alpha; &lambda; &omega; }</span><span class="wr-label">webring</span></a></div>
    <div class="bp-right"><img class="webring-icon" src="/assets-1024x768/iczelia-128.png" alt="lambda"></div>
  </aside>
  <aside class="bot-frame blog-win">
    <div class="bot tl"></div><div class="bot tm"></div><div class="bot tr"></div>
    <div class="bot ml"></div><div class="bot mm"></div><div class="bot mr"></div>
    <div class="bot bl"></div><div class="bot bm"></div><div class="bot br"></div>
    <div class="bot-head">:: latest from the blog ::</div>
    <div class="bot-body">
{% if blog_teaser %}      <p class="blog-line"><span class="blog-date">&raquo; {{ blog_teaser.date_fmt }}</span> <span class="blog-headline">{{ blog_teaser.title }}</span> <a class="blog-more" href="{{ blog_teaser.url }}">&gt; read more</a></p>
{% else %}      <p class="blog-line"><span class="blog-headline">no posts yet.</span></p>
{% endif %}    </div>
  </aside>
  <div class="clock">{{ clock }}</div>
  <div class="status-bar">
    <div class="sb-start"></div>
    <div class="sb-mid">
      <span class="sb-text"><span class="sb-url">{{ site.base_url }} // </span><span class="sb-prefix">all content </span>{{ site.copyright_short }} <span class="sb-author">{{ site.copyright_author }}</span><span class="sb-extra"> // email: {% include "partials/email.tpl" %}</span></span>
    </div>
    <div class="sb-end"></div>
    <span class="sb-mobile-email">email: {% include "partials/email.tpl" %}</span>
  </div>
</div>
</body>
</html>
