/* Static subpage file editor. Vanilla, reuses the admin's CodeMirror. */
(function () {
  'use strict';

  var root = document.getElementById('cms-subpages');
  if (!root) return;
  var spId = root.getAttribute('data-id');
  var csrf = root.getAttribute('data-csrf');

  var pathInput = document.getElementById('cms-subpage-path');
  var ta        = document.getElementById('cms-subpage-content');
  var saveBtn   = document.getElementById('cms-subpage-save');
  var newBtn    = document.getElementById('cms-subpage-newfile');
  var statusEl  = document.getElementById('cms-subpage-status');
  if (!ta || !pathInput || !saveBtn) return;

  function $$(sel) {
    return Array.prototype.slice.call(document.querySelectorAll(sel));
  }

  var cm = null;
  if (typeof CodeMirror !== 'undefined') {
    cm = CodeMirror.fromTextArea(ta, {
      lineNumbers:     true,
      lineWrapping:    true,
      theme:           'eclipse',
      tabSize:         2,
      indentUnit:      2,
      styleActiveLine: true
    });
    cm.setSize(null, 440);
  }
  function getVal()  { return cm ? cm.getValue() : ta.value; }
  function setVal(v) { if (cm) { cm.setValue(v); } else { ta.value = v; } }

  function flash(msg, kind) {
    statusEl.textContent = msg;
    statusEl.className =
      'cms-subpage-status' + (kind ? ' cms-subpage-status-' + kind : '');
  }

  function rowFor(path) {
    var rows = $$('.cms-subpage-files tr[data-path]');
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].getAttribute('data-path') === path) return rows[i];
    }
    return null;
  }

  function loadFile(path) {
    flash('loading ' + path + '…');
    fetch('/admin/subpages/' + spId + '/file?path=' + encodeURIComponent(path),
      { credentials: 'same-origin' })
      .then(function (r) {
        if (!r.ok) throw new Error('HTTP ' + r.status);
        return r.text();
      })
      .then(function (text) {
        pathInput.value = path;
        setVal(text);
        flash('editing ' + path, 'ok');
        if (cm) cm.focus();
      })
      .catch(function (e) { flash('could not load: ' + e.message, 'err'); });
  }

  function save() {
    var path = (pathInput.value || '').replace(/^\s+|\s+$/g, '');
    if (!path) { flash('enter a file path first', 'err'); return; }
    var fd = new FormData();
    fd.append('csrf', csrf);
    fd.append('path', path);
    fd.append('content', getVal());
    flash('saving…');
    fetch('/admin/subpages/' + spId + '/file/save',
      { method: 'POST', credentials: 'same-origin', body: fd })
      .then(function (r) {
        return r.json().then(function (j) { return { ok: r.ok, j: j }; });
      })
      .then(function (res) {
        if (!res.ok || !res.j.ok) {
          throw new Error(res.j.error || 'save failed');
        }
        flash('saved ' + res.j.path + ' ✓', 'ok');
        // A new file is not in the list yet; reload to show it.
        if (!rowFor(res.j.path)) window.location.reload();
      })
      .catch(function (e) { flash('save failed: ' + e.message, 'err'); });
  }

  $$('.cms-subpage-files .js-edit').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var tr = btn.closest('tr');
      if (tr) loadFile(tr.getAttribute('data-path'));
    });
  });

  saveBtn.addEventListener('click', save);
  if (newBtn) {
    newBtn.addEventListener('click', function () {
      pathInput.value = '';
      setVal('');
      flash('new file: type a path, then save', 'ok');
      pathInput.focus();
    });
  }
})();
