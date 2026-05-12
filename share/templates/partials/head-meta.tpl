<meta name="description" content="{{ meta.description }}">
{% if meta.keywords %}<meta name="keywords" content="{{ meta.keywords }}">{% endif %}
{% if site.author %}<meta name="author" content="{{ site.author }}">{% endif %}
{% if meta.robots %}<meta name="robots" content="{{ meta.robots }}">{% endif %}
{% if meta.canonical %}<link rel="canonical" href="{{ meta.canonical }}">{% endif %}
<meta name="twitter:card" content="summary">
<meta property="og:type" content="{{ meta.og_type }}">
<meta property="og:title" content="{{ meta.og_title }}">
<meta property="og:description" content="{{ meta.description }}">
<meta property="og:site_name" content="{{ site.title }}">
<meta property="og:locale" content="{{ meta.og_locale }}">
{% if meta.og_url %}<meta property="og:url" content="{{ meta.og_url }}">{% endif %}
{% if meta.image %}<meta property="og:image" content="{{ meta.image }}">{% endif %}
{% if meta.published_time %}<meta property="article:published_time" content="{{ meta.published_time }}">{% endif %}
{% if meta.modified_time %}<meta property="article:modified_time" content="{{ meta.modified_time }}">{% endif %}
