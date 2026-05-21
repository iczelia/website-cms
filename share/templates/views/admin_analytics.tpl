{% extends "layouts/admin.tpl" %}
{% block content %}
<article class="cms-analytics" id="cms-analytics-app" data-endpoint="/admin/analytics/data.json">
  <noscript>
    <p class="cms-error">The analytics dashboard needs JavaScript. <a href="/admin/analytics/raw">Browse raw events</a> instead.</p>
  </noscript>
  <p class="cms-anal-loading">loading analytics&hellip;</p>
</article>
{% endblock %}
{% block scripts %}<script src="/cms-analytics.js"></script>
{% endblock %}
