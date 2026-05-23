/* Hand-rolled, no framework. Uses vendored CodeMirror 5 + marked.js. */
(function () {
  'use strict';

  var hasCM     = typeof CodeMirror !== 'undefined';
  var hasMarked = typeof marked     !== 'undefined';

  function $$(sel, root) { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); }
  function el(tag, attrs, kids) {
    var n = document.createElement(tag);
    if (attrs) for (var k in attrs) {
      if (k === 'class') n.className = attrs[k];
      else if (k === 'text') n.textContent = attrs[k];
      else n.setAttribute(k, attrs[k]);
    }
    if (kids) kids.forEach(function (c) { n.appendChild(c); });
    return n;
  }
  function debounce(fn, ms) {
    var t;
    return function () { clearTimeout(t); var a = arguments, self = this;
      t = setTimeout(function(){ fn.apply(self, a); }, ms); };
  }
  function getCookie(name) {
    var m = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
    return m ? decodeURIComponent(m[1]) : '';
  }
  function metaToken(name) {
    var meta = document.querySelector('meta[name="' + name + '"]');
    return meta ? meta.getAttribute('content') : '';
  }
  function csrfPreviewToken() { return metaToken('cms-preview-csrf'); }
  function csrfUploadToken()  { return metaToken('cms-upload-csrf');  }

  function setupEditor(textarea) {
    if (!hasCM) return null;

    var cm = CodeMirror.fromTextArea(textarea, {
      mode:        'markdown',
      lineNumbers: false,
      lineWrapping:true,
      theme:       'eclipse',
      tabSize:     2,
      indentUnit:  2,
      styleActiveLine: true,
      extraKeys: {
        'Tab':       function (cm) { cm.replaceSelection('  ', 'end'); },
        'Ctrl-B':    function (cm) { wrap(cm, '**', '**'); },
        'Ctrl-I':    function (cm) { wrap(cm, '*',  '*');  },
        'Ctrl-K':    function (cm) { insertLink(cm); },
      }
    });
    cm.setSize(null, '100%');
    return cm;
  }

  function wrap(cm, before, after) {
    var sel = cm.getSelection();
    cm.replaceSelection(before + sel + after, 'around');
    if (!sel) {
      var p = cm.getCursor();
      cm.setCursor({ line: p.line, ch: p.ch - after.length });
    }
    cm.focus();
  }
  function insertLink(cm) {
    var sel  = cm.getSelection() || 'text';
    var url  = prompt('URL:', 'https://');
    if (url === null) return;
    cm.replaceSelection('[' + sel + '](' + url + ')', 'around');
    cm.focus();
  }
  function lineCmd(cm, prefix) {
    var sel = cm.listSelections()[0];
    var ln  = sel.head.line;
    var line = cm.getLine(ln);
    cm.replaceRange(prefix + line,
        { line: ln, ch: 0 },
        { line: ln, ch: line.length });
    cm.focus();
  }

  function buildToolbar(cm, fieldName) {
    var bar = el('div', { class: 'cms-toolbar' });
    var btns = [
      ['H2',     function () { lineCmd(cm, '## '); }],
      ['H3',     function () { lineCmd(cm, '### '); }],
      ['B',      function () { wrap(cm, '**', '**'); }],
      ['i',      function () { wrap(cm, '*',  '*');  }],
      ['<>',     function () { wrap(cm, '`', '`'); }],
      ['link',   function () { insertLink(cm); }],
      ['$',      function () { wrap(cm, '$', '$'); }],
      ['$$',     function () { wrap(cm, '\n$$\n', '\n$$\n'); }],
      ['*',      function () { lineCmd(cm, '- '); }],
      ['1.',     function () { lineCmd(cm, '1. '); }],
      ['>',      function () { lineCmd(cm, '> '); }],
    ];
    btns.forEach(function (b) {
      var btn = el('button', { type: 'button', class: 'cms-tb-btn', title: b[0], 'aria-label': b[0] });
      btn.textContent = b[0];
      btn.addEventListener('click', function (e) { e.preventDefault(); b[1](); });
      bar.appendChild(btn);
    });
    return bar;
  }

  // Posts a debounced fetch to /admin/preview and injects the rendered
  // HTML. This is the same pipeline that runs on save, so math, code
  // highlighting, footnotes, and tables all match the public page
  // exactly. Falls back to client-side marked.js if no CSRF token is
  // present (e.g. embedded in a non-admin page).
  function setupPreview(cm, container) {
    var existing = document.getElementById('server-preview');
    var pane = existing || el('div', { class: 'cms-server-preview', id: 'server-preview' });
    if (!existing) container.appendChild(pane);

    var meta = document.querySelector('meta[name="cms-preview-csrf"]');
    var token = meta ? meta.getAttribute('content') : null;
    if (!token && hasMarked) return setupClientPreview(cm, pane);
    if (!token) {
      pane.innerHTML = '<p class="preview-err">no csrf-preview token; preview disabled.</p>';
      return;
    }

    var ctrl = null;
    function rerender() {
      if (ctrl) ctrl.abort();
      ctrl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
      var fd = new FormData();
      fd.append('csrf', token);
      fd.append('body', cm.getValue());
      fetch('/admin/preview', {
        method: 'POST',
        body: fd,
        credentials: 'same-origin',
        signal: ctrl ? ctrl.signal : undefined,
      }).then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text();
      }).then(function (html) {
        pane.innerHTML = html;
      }).catch(function (e) {
        if (e.name === 'AbortError') return;
        pane.innerHTML = '<p class="preview-err">' + (e.message || 'preview error') + '</p>';
      });
    }
    cm.on('change', debounce(rerender, 400));
    rerender();
  }

  // Fallback when no CSRF token is available (rare; used outside admin).
  function setupClientPreview(cm, pane) {
    function rerender() {
      var src = cm.getValue();
      var out = src
        .replace(/\$\$([^\$]+)\$\$/g, '<code class="math-display">$$$$$1$$$$</code>')
        .replace(/\$([^\$\n]+)\$/g,    '<code class="math-inline">$$$1$$</code>');
      try {
        pane.innerHTML = marked.parse(out);
      } catch (e) {
        pane.innerHTML = '<p class="preview-err">' + (e.message || 'parse error') + '</p>';
      }
    }
    cm.on('change', debounce(rerender, 200));
    rerender();
  }

  function setupKvTable(table) {
    var fname = table.getAttribute('data-field');
    var addBtn = document.querySelector(
      '.cms-kvtable-add [data-field="' + fname + '"]');

    function rowCount() {
      return table.querySelectorAll('tbody > tr').length;
    }

    function renumberRows() {
      table.querySelectorAll('tbody > tr').forEach(function(tr, i) {
        tr.querySelectorAll('input').forEach(function(inp) {
          inp.name = inp.name.replace(/row\d+/, 'row' + i);
        });
      });
    }

    function newRow() {
      var idx = rowCount();
      var tr = document.createElement('tr');
      var headers = table.querySelectorAll('thead th');
      for (var i = 0; i < headers.length; i++) {
        var th = headers[i];
        var td = document.createElement('td');
        if (th.classList.contains('cms-kvtable-actions')) {
          var del = document.createElement('button');
          del.type = 'button'; del.className = 'cms-row-del';
          del.innerHTML = '&times;';
          td.appendChild(del);
        } else if (th.classList.contains('cms-kvtable-handle')) {
          td.className = 'cms-kvtable-handle';
          var span = document.createElement('span');
          span.className = 'cms-drag-handle';
          span.draggable = true;
          span.textContent = '⠿';
          td.appendChild(span);
        } else {
          var input = document.createElement('input');
          input.type = 'text';
          var colName = inferColName(table, i);
          input.name = fname + '__row' + idx + '__' + colName;
          td.appendChild(input);
        }
        tr.appendChild(td);
      }
      table.querySelector('tbody').appendChild(tr);
      tr.querySelector('input').focus();
    }

    function inferColName(tab, colIdx) {
      var first = tab.querySelector('tbody tr');
      if (!first) return 'col' + colIdx;
      var inp = first.children[colIdx].querySelector('input');
      if (!inp) return 'col' + colIdx;
      var m = inp.name.match(/__([\w-]+)$/);
      return m ? m[1] : 'col' + colIdx;
    }

    if (addBtn) addBtn.addEventListener('click', newRow);

    table.addEventListener('click', function (e) {
      if (e.target.classList.contains('cms-row-del')) {
        var tr = e.target.closest('tr');
        if (tr) tr.parentNode.removeChild(tr);
      }
    });

    var dragSrc = null;

    table.addEventListener('dragstart', function(e) {
      if (!e.target.classList.contains('cms-drag-handle')) return;
      dragSrc = e.target.closest('tr');
      e.dataTransfer.effectAllowed = 'move';
      e.dataTransfer.setData('text/plain', '');
      setTimeout(function() { if (dragSrc) dragSrc.classList.add('cms-dragging'); }, 0);
    });

    table.addEventListener('dragend', function() {
      if (dragSrc) dragSrc.classList.remove('cms-dragging');
      table.querySelectorAll('.cms-drag-over').forEach(function(el) {
        el.classList.remove('cms-drag-over');
      });
      dragSrc = null;
    });

    table.addEventListener('dragover', function(e) {
      if (!dragSrc) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
      var tr = e.target.closest('tbody tr');
      if (!tr || tr === dragSrc) return;
      table.querySelectorAll('.cms-drag-over').forEach(function(el) {
        el.classList.remove('cms-drag-over');
      });
      tr.classList.add('cms-drag-over');
    });

    table.addEventListener('drop', function(e) {
      if (!dragSrc) return;
      e.preventDefault();
      var tr = e.target.closest('tbody tr');
      if (!tr || tr === dragSrc) return;
      var tbody = table.querySelector('tbody');
      var rect = tr.getBoundingClientRect();
      if (e.clientY < rect.top + rect.height / 2) {
        tbody.insertBefore(dragSrc, tr);
      } else {
        tbody.insertBefore(dragSrc, tr.nextSibling);
      }
      tr.classList.remove('cms-drag-over');
      renumberRows();
    });
  }

  function setupSlugAutofill() {
    var title = document.querySelector('input[name="title"]');
    var slug  = document.querySelector('input[name="slug"]');
    if (!title || !slug) return;
    var dirty = (slug.value && slug.value.length > 0);
    slug.addEventListener('input', function () { dirty = true; });
    title.addEventListener('input', function () {
      if (dirty) return;
      slug.value = title.value
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .substring(0, 80);
    });
  }

  function setupImagePaste(cm) {
    if (!cm) return;
    var dom = cm.getWrapperElement();
    function uploadAndInsert(file) {
      var fd = new FormData();
      fd.append('file', file);
      fd.append('csrf', csrfUploadToken());
      fetch('/admin/media/upload', {
        method: 'POST', body: fd, credentials: 'same-origin',
      }).then(function (r) {
        return r.json().catch(function () { return null; });
      }).then(function (j) {
        if (j && j.url) {
          var alt = file.name.replace(/\.[^.]+$/, '');
          cm.replaceSelection('![' + alt + '](' + j.url + ')');
        }
      });
    }
    dom.addEventListener('paste', function (e) {
      var items = (e.clipboardData || {}).items || [];
      for (var i = 0; i < items.length; i++) {
        if (items[i].kind === 'file' && /^image\//.test(items[i].type)) {
          uploadAndInsert(items[i].getAsFile());
          e.preventDefault();
          return;
        }
      }
    });
    dom.addEventListener('drop', function (e) {
      if (e.dataTransfer.files && e.dataTransfer.files.length) {
        for (var i = 0; i < e.dataTransfer.files.length; i++) {
          var f = e.dataTransfer.files[i];
          if (/^image\//.test(f.type)) {
            uploadAndInsert(f);
            e.preventDefault();
            return;
          }
        }
      }
    });
  }

  function setupUnsavedGuard() {
    var forms = $$('form.cms-form');
    if (!forms.length) return;
    var dirty = false;
    forms.forEach(function (form) {
      form.addEventListener('input',  function () { dirty = true; });
      form.addEventListener('submit', function () { dirty = false; });
    });
    window.addEventListener('beforeunload', function (e) {
      if (!dirty) return;
      e.preventDefault();
      e.returnValue = '';
    });
  }

  function init() {
    var cms = [];
    $$('.cm-md').forEach(function (ta) {
      var cm = setupEditor(ta);
      if (!cm) return;
      cms.push(cm);
      // Toolbar: prepend
      var bar = buildToolbar(cm, ta.name);
      var wrap = cm.getWrapperElement();
      wrap.parentNode.insertBefore(bar, wrap);
      // Live preview on the post-body editor only
      if (ta.name === 'body') {
        var grid = document.querySelector('.cms-edit-grid');
        if (grid && grid.querySelector('.cms-edit-main')) {
          setupPreview(cm, grid.querySelector('.cms-edit-main'));
        }
      }
      setupImagePaste(cm);
    });

    $$('.cms-kvtable').forEach(setupKvTable);
    setupSlugAutofill();
    setupTagPicker();
    setupUnsavedGuard();
  }

  function setupTagPicker() {
    var picker = document.querySelector('[data-cms-tag-picker]');
    var input  = document.querySelector('[data-cms-tag-input]');
    if (!picker || !input) return;

    function parseTags(s) {
      return (s || '').split(',').map(function (t) { return t.trim(); })
                      .filter(function (t) { return t.length; });
    }
    function syncList() {
      var have = {};
      parseTags(input.value).forEach(function (t) { have[t] = 1; });
      $$('.cms-tag-item', picker).forEach(function (li) {
        var t = li.getAttribute('data-tag');
        li.classList.toggle('cms-tag-item-on', !!have[t]);
        li.setAttribute('aria-selected', have[t] ? 'true' : 'false');
      });
    }
    function toggle(tag) {
      var tags = parseTags(input.value);
      var idx = tags.indexOf(tag);
      if (idx >= 0) tags.splice(idx, 1);
      else          tags.push(tag);
      input.value = tags.join(', ');
      input.dispatchEvent(new Event('input', { bubbles: true }));
      syncList();
    }
    picker.addEventListener('dblclick', function (e) {
      var li = e.target.closest && e.target.closest('.cms-tag-item');
      if (!li) return;
      e.preventDefault();
      toggle(li.getAttribute('data-tag'));
    });
    picker.addEventListener('keydown', function (e) {
      if (e.key !== 'Enter' && e.key !== ' ') return;
      var li = e.target.closest && e.target.closest('.cms-tag-item');
      if (!li) return;
      e.preventDefault();
      toggle(li.getAttribute('data-tag'));
    });
    input.addEventListener('input', syncList);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
