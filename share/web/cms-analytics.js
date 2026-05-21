/* Analytics dashboard. Vanilla, no framework. Renders client-side
   from /admin/analytics/data.json. */
(function () {
  'use strict';

  var app = document.getElementById('cms-analytics-app');
  if (!app) return;
  var ENDPOINT = app.getAttribute('data-endpoint') || '/admin/analytics/data.json';

  var RANGES   = [['7d', '7 days'], ['30d', '30 days'], ['all', 'all time']];
  var UA_TABS  = [
    ['browsers', 'browsers'], ['os', 'operating systems'],
    ['devices',  'devices'],  ['bots', 'bots']
  ];

  var state = {
    range:   '7d',
    bots:    'show',
    metric:  'views',
    uaTab:   'browsers',
    sort:    { key: 'views', dir: -1 },
    data:    null,
    loading: false,
    error:   null
  };

  function el(tag, attrs, kids) {
    var n = document.createElement(tag);
    if (attrs) for (var k in attrs) {
      if (k === 'class')      n.className   = attrs[k];
      else if (k === 'text')  n.textContent = attrs[k];
      else if (k === 'html')  n.innerHTML   = attrs[k];
      else if (k === 'on')    { for (var ev in attrs[k]) n.addEventListener(ev, attrs[k][ev]); }
      else if (attrs[k] != null) n.setAttribute(k, attrs[k]);
    }
    if (kids) kids.forEach(function (c) { if (c) n.appendChild(c); });
    return n;
  }
  function svg(tag, attrs) {
    var n = document.createElementNS('http://www.w3.org/2000/svg', tag);
    if (attrs) for (var k in attrs) n.setAttribute(k, attrs[k]);
    return n;
  }
  function num(x)  { return typeof x === 'number' ? x : (parseFloat(x) || 0); }
  function fmt(x)  { return num(x).toLocaleString(); }
  function pct(a, b) { return b > 0 ? (a / b * 100).toFixed(1) + '%' : '0%'; }
  function clear(n) { while (n.firstChild) n.removeChild(n.firstChild); }

  function syncUrl() {
    var q = '?range=' + state.range + (state.bots === 'hide' ? '&bots=hide' : '');
    history.replaceState(null, '', '/admin/analytics/' + q);
  }

  function load() {
    state.loading = true;
    state.error   = null;
    render();
    var url = ENDPOINT + '?range=' + encodeURIComponent(state.range) +
              '&bots=' + encodeURIComponent(state.bots);
    fetch(url, { credentials: 'same-origin', headers: { 'Accept': 'application/json' } })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.json();
      })
      .then(function (d) {
        state.data    = d;
        state.loading = false;
        if (d.bots_hidden && state.uaTab === 'bots') state.uaTab = 'browsers';
        render();
      })
      .catch(function (e) {
        state.loading = false;
        state.error   = e.message || 'request failed';
        render();
      });
  }

  /* controls */
  function controls() {
    var d = state.data;
    var bar = el('div', { class: 'cms-anal-controls' });

    var rg = el('span', { class: 'cms-anal-segctl' });
    RANGES.forEach(function (r) {
      rg.appendChild(el('button', {
        class: 'cms-seg' + (state.range === r[0] ? ' cms-seg-on' : ''),
        type:  'button', text: r[1],
        on: { click: function () {
          if (state.range === r[0]) return;
          state.range = r[0]; syncUrl(); load();
        } }
      }));
    });
    bar.appendChild(el('span', { class: 'cms-anal-ctl' }, [
      el('span', { class: 'cms-anal-lbl', text: 'range' }), rg
    ]));

    var botsBox = el('input', { type: 'checkbox' });
    botsBox.checked = state.bots === 'hide';
    botsBox.addEventListener('change', function () {
      state.bots = botsBox.checked ? 'hide' : 'show';
      syncUrl(); load();
    });
    bar.appendChild(el('label', { class: 'cms-anal-check' }, [
      botsBox, el('span', { text: ' exclude bots' })
    ]));

    var right = el('span', { class: 'cms-anal-ctl-right' });
    right.appendChild(el('button', {
      class: 'cms-seg', type: 'button', text: 'refresh',
      on: { click: load }
    }));
    right.appendChild(el('a', {
      class: 'cms-anal-rawlink', href: '/admin/analytics/raw',
      text: 'raw events »'
    }));
    if (d && d.generated_at) {
      right.appendChild(el('span', {
        class: 'cms-anal-stamp',
        text:  'as of ' + new Date(d.generated_at * 1000)
                 .toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
      }));
    }
    bar.appendChild(right);
    return bar;
  }

  /* totals cards */
  function cards() {
    var t = state.data.totals || { views: 0, uniques: 0, bots: 0 };
    var views = num(t.views), bots = num(t.bots);
    var defs = [
      ['views',          fmt(views),            ''],
      ['unique visitors', fmt(t.uniques),       ''],
      ['human views',    fmt(views - bots),     pct(views - bots, views) + ' of views'],
      ['bot hits',       fmt(bots),             pct(bots, views) + ' of views']
    ];
    var wrap = el('section', { class: 'cms-anal-cards' });
    defs.forEach(function (c) {
      wrap.appendChild(el('div', { class: 'cms-anal-card' }, [
        el('strong', { text: c[1] }),
        el('span', { class: 'cms-anal-card-lbl', text: c[0] }),
        c[2] ? el('span', { class: 'cms-anal-card-sub', text: c[2] }) : null
      ]));
    });
    return wrap;
  }

  /* per-day bar chart */
  function chart() {
    var days   = state.data.days || [];
    var box    = el('section', { class: 'cms-anal-block' });
    var head   = el('div', { class: 'cms-anal-head' }, [
      el('h2', { text: 'traffic per day' })
    ]);
    var seg = el('span', { class: 'cms-anal-segctl' });
    [['views', 'views'], ['uniques', 'uniques'], ['bots', 'bots']]
      .forEach(function (m) {
        seg.appendChild(el('button', {
          class: 'cms-seg' + (state.metric === m[0] ? ' cms-seg-on' : ''),
          type:  'button', text: m[1],
          on: { click: function () { state.metric = m[0]; render(); } }
        }));
      });
    head.appendChild(seg);
    box.appendChild(head);

    if (!days.length) {
      box.appendChild(el('p', { class: 'cms-anal-empty', text: 'no data in this range.' }));
      return box;
    }

    var metric = state.metric;
    var n = days.length;
    var padL = 44, padR = 14, padT = 14, padB = 46;
    var slot = Math.max(20, Math.min(64, Math.floor(900 / n)));
    var W = padL + padR + slot * n;
    var H = 260;
    var areaH = H - padT - padB;
    var max = 1;
    days.forEach(function (d) { max = Math.max(max, num(d[metric])); });

    var s = svg('svg', {
      'class': 'cms-chart', viewBox: '0 0 ' + W + ' ' + H,
      preserveAspectRatio: 'xMidYMid meet'
    });

    [0, 0.5, 1].forEach(function (f) {
      var y = padT + areaH * (1 - f);
      s.appendChild(svg('line', {
        x1: padL, y1: y, x2: W - padR, y2: y, 'class': 'cms-chart-grid'
      }));
      var lbl = svg('text', { x: padL - 6, y: y + 3, 'class': 'cms-chart-axis', 'text-anchor': 'end' });
      lbl.textContent = fmt(Math.round(max * f));
      s.appendChild(lbl);
    });

    var labelEvery = Math.ceil(n / 12);
    var cont = el('div', { class: 'cms-chart-box' });
    var tip  = el('div', { class: 'cms-chart-tip' });

    days.forEach(function (d, i) {
      var v  = num(d[metric]);
      var bh = max > 0 ? (v / max) * areaH : 0;
      var x  = padL + slot * i + slot * 0.15;
      var bw = slot * 0.7;
      var y  = padT + areaH - bh;
      var rect = svg('rect', {
        x: x.toFixed(1), y: y.toFixed(1),
        width: bw.toFixed(1), height: Math.max(0, bh).toFixed(1),
        'class': 'cms-chart-bar cms-chart-bar-' + metric
      });
      rect.addEventListener('mouseenter', function () {
        rect.classList.add('cms-chart-bar-on');
        tip.innerHTML = '<strong>' + d.date + '</strong>' +
          '<span>' + fmt(d.views)   + ' views</span>' +
          '<span>' + fmt(d.uniques) + ' uniques</span>' +
          '<span>' + fmt(d.bots)    + ' bots</span>';
        tip.style.display = 'block';
      });
      rect.addEventListener('mousemove', function (ev) {
        var r = cont.getBoundingClientRect();
        var tx = ev.clientX - r.left, ty = ev.clientY - r.top;
        tip.style.left = Math.min(tx + 12, r.width - 140) + 'px';
        tip.style.top  = Math.max(0, ty - 60) + 'px';
      });
      rect.addEventListener('mouseleave', function () {
        rect.classList.remove('cms-chart-bar-on');
        tip.style.display = 'none';
      });
      s.appendChild(rect);

      if (i % labelEvery === 0) {
        var t = svg('text', {
          x: (padL + slot * i + slot / 2).toFixed(1),
          y: H - padB + 16, 'class': 'cms-chart-axis',
          'text-anchor': 'middle'
        });
        t.textContent = String(d.date).slice(5);
        s.appendChild(t);
      }
    });

    cont.appendChild(s);
    cont.appendChild(tip);
    box.appendChild(cont);
    return box;
  }

  /* sortable table of top paths */
  function pathsTable() {
    var rows = (state.data.top_paths || []).slice();
    var box  = el('section', { class: 'cms-anal-block' }, [
      el('h2', { text: 'top pages' })
    ]);
    if (!rows.length) {
      box.appendChild(el('p', { class: 'cms-anal-empty', text: 'no page views in this range.' }));
      return box;
    }
    var cols = [
      ['path', 'path', 1], ['views', 'views', -1],
      ['uniques', 'uniques', -1], ['bots', 'bots', -1]
    ];
    var sk = state.sort.key, sd = state.sort.dir;
    rows.sort(function (a, b) {
      var x = a[sk], y = b[sk];
      if (sk === 'path') return sd * String(x).localeCompare(String(y));
      return sd * (num(x) - num(y));
    });

    var thead = el('tr');
    cols.forEach(function (c) {
      var on = sk === c[0];
      thead.appendChild(el('th', {
        class: 'cms-sortable' + (on ? ' cms-sort-' + (sd < 0 ? 'desc' : 'asc') : ''),
        text:  c[1] + (on ? (sd < 0 ? ' ▾' : ' ▴') : ''),
        on: { click: function () {
          if (state.sort.key === c[0]) state.sort.dir *= -1;
          else state.sort = { key: c[0], dir: c[2] };
          render();
        } }
      }));
    });
    var tbody = el('tbody');
    rows.forEach(function (r) {
      tbody.appendChild(el('tr', null, [
        el('td', null, [el('code', { text: r.path })]),
        el('td', { text: fmt(r.views) }),
        el('td', { text: fmt(r.uniques) }),
        el('td', { text: fmt(r.bots) })
      ]));
    });
    box.appendChild(el('table', { class: 'cms-table cms-anal-table' }, [
      el('thead', null, [thead]), tbody
    ]));
    return box;
  }

  /* horizontal bar list, shared by referrers and UA breakdowns */
  function barList(rows, labelKey, opts) {
    opts = opts || {};
    var max = 1, total = 0;
    rows.forEach(function (r) {
      max = Math.max(max, num(r.count));
      total += num(r.count);
    });
    var list = el('div', { class: 'cms-barlist' });
    rows.forEach(function (r) {
      var c = num(r.count);
      var label = r[labelKey];
      if (label == null || label === '') label = '(none)';
      var row = el('div', { class: 'cms-barlist-row' });
      row.appendChild(el('span', { class: 'cms-barlist-label', title: label, text: label }));
      var track = el('span', { class: 'cms-barlist-track' }, [
        el('span', {
          class: 'cms-barlist-fill' + (opts.fillClass ? ' ' + opts.fillClass : ''),
          style: 'width:' + (c / max * 100).toFixed(1) + '%'
        })
      ]);
      row.appendChild(track);
      row.appendChild(el('span', { class: 'cms-barlist-count', text: fmt(c) }));
      row.appendChild(el('span', { class: 'cms-barlist-pct', text: pct(c, total) }));
      list.appendChild(row);
    });
    return list;
  }

  function referrers() {
    var rows = state.data.top_refs || [];
    var box  = el('section', { class: 'cms-anal-block' }, [
      el('h2', { text: 'top referrers' })
    ]);
    if (!rows.length) {
      box.appendChild(el('p', { class: 'cms-anal-empty', text: 'no off-site referrers in this range.' }));
      return box;
    }
    box.appendChild(barList(rows, 'host', { fillClass: 'cms-fill-ref' }));
    return box;
  }

  /* tabbed UA breakdown */
  function uaBreakdown() {
    var ua  = state.data.ua || {};
    var hideBots = !!state.data.bots_hidden;
    var box = el('section', { class: 'cms-anal-block' });
    var head = el('div', { class: 'cms-anal-head' }, [
      el('h2', { text: 'visitor breakdown' })
    ]);
    var tabs = el('span', { class: 'cms-anal-segctl' });
    UA_TABS.forEach(function (t) {
      if (t[0] === 'bots' && hideBots) return;
      tabs.appendChild(el('button', {
        class: 'cms-seg' + (state.uaTab === t[0] ? ' cms-seg-on' : ''),
        type:  'button', text: t[1],
        on: { click: function () { state.uaTab = t[0]; render(); } }
      }));
    });
    head.appendChild(tabs);
    box.appendChild(head);

    var key  = state.uaTab;
    var rows = (ua[key] || []).slice();
    if (key === 'devices' && hideBots) {
      rows = rows.filter(function (r) { return r.label !== 'bot'; });
    }
    if (!rows.length) {
      box.appendChild(el('p', { class: 'cms-anal-empty', text: 'no data yet; breakdowns appear once events roll up.' }));
      return box;
    }
    box.appendChild(barList(rows, 'label', { fillClass: 'cms-fill-' + key }));
    if (key === 'bots') {
      box.appendChild(el('p', { class: 'cms-anal-note',
        text: 'raw bot UA strings. human UAs are never stored; only the derived families above.' }));
    }
    return box;
  }

  function render() {
    clear(app);

    if (state.error) {
      app.appendChild(el('p', { class: 'cms-error' }, [
        el('span', { text: 'could not load analytics: ' + state.error + '. ' }),
        el('button', { class: 'cms-seg', type: 'button', text: 'retry', on: { click: load } })
      ]));
      return;
    }
    if (!state.data) {
      app.appendChild(el('p', { class: 'cms-anal-loading', text: 'loading analytics…' }));
      return;
    }

    app.appendChild(el('header', { class: 'cms-edit-head' }, [
      el('h1', { text: 'analytics' }),
      el('p', { class: 'cms-meta',
        text: 'server-side, cookieless. no tracking JS on the public site, no IPs or raw human UAs stored. visitor_hash = sha256(ip + ua + daily salt) truncated to 16 hex.' })
    ]));
    app.appendChild(controls());
    if (state.loading) {
      app.appendChild(el('p', { class: 'cms-anal-loading', text: 'refreshing…' }));
    }
    app.appendChild(cards());
    app.appendChild(chart());
    app.appendChild(pathsTable());
    app.appendChild(uaBreakdown());
    app.appendChild(referrers());
  }

  /* initial state from the URL the page was opened with */
  (function init() {
    var q = new URLSearchParams(location.search);
    var r = q.get('range');
    if (r === '7d' || r === '30d' || r === 'all') state.range = r;
    if (q.get('bots') === 'hide') state.bots = 'hide';
    load();
  })();
})();
