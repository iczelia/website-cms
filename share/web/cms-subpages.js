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
    flash('loading ' + path + '...');
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
    flash('saving...');
    fetch('/admin/subpages/' + spId + '/file/save',
      { method: 'POST', credentials: 'same-origin', body: fd })
      .then(function (r) {
        return r.json().then(function (j) { return { ok: r.ok, j: j }; });
      })
      .then(function (res) {
        if (!res.ok || !res.j.ok) {
          throw new Error(res.j.error || 'save failed');
        }
        flash('saved ' + res.j.path + ' ', 'ok');
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
      var prefix = newBtn.getAttribute('data-prefix') || '';
      pathInput.value = prefix;
      setVal('');
      flash('new file: type a path, then save', 'ok');
      pathInput.focus();
      if (pathInput.setSelectionRange) {
        var n = pathInput.value.length;
        pathInput.setSelectionRange(n, n);
      }
    });
  }

  // Multi-file / directory uploader. Small files are grouped into bounded
  // multipart requests; large files reuse cms-upload.js's resumable 2 MiB
  // chunk transport and are finalized one at a time at their relative path.
  var uploadForm = document.getElementById('cms-subpage-upload');
  var filesInput = document.getElementById('cms-subpage-upload-files');
  var dirInput = document.getElementById('cms-subpage-upload-directory');
  var uploadPath = document.getElementById('cms-subpage-upload-path');
  var uploadStatus = document.getElementById('cms-subpage-upload-status');

  function uploadFlash(msg, kind) {
    if (!uploadStatus) return;
    uploadStatus.textContent = msg;
    uploadStatus.className = 'cms-subpage-upload-status'
      + (kind ? ' cms-subpage-upload-status-' + kind : '');
  }

  function selectedUploads() {
    var out = [];
    var i, f, rel;
    if (filesInput && filesInput.files) {
      for (i = 0; i < filesInput.files.length; i++) {
        f = filesInput.files[i];
        out.push({ file: f, path: f.name });
      }
    }
    if (dirInput && dirInput.files) {
      for (i = 0; i < dirInput.files.length; i++) {
        f = dirInput.files[i];
        rel = f.webkitRelativePath || f.name;
        out.push({ file: f, path: rel });
      }
    }
    return out;
  }

  function responseJSON(r) {
    return r.json().then(function (j) {
      if (!r.ok || !j.ok) {
        throw new Error(j && j.error ? j.error : 'HTTP ' + r.status);
      }
      return j;
    }, function () {
      throw new Error('non-JSON response (HTTP ' + r.status + ')');
    });
  }

  function postSmallGroup(items) {
    var fd = new FormData();
    var paths = [];
    fd.append('csrf', csrf);
    fd.append('dir', root.getAttribute('data-dir') || '');
    fd.append('batch', '1');
    for (var i = 0; i < items.length; i++) {
      paths.push(items[i].path);
      fd.append('files', items[i].file, items[i].file.name);
    }
    if (items.length === 1 && items[0].explicitPath) {
      fd.append('path', items[0].path);
    } else {
      fd.append('paths', JSON.stringify(paths));
    }
    return fetch(uploadForm.action, {
      method: 'POST', credentials: 'same-origin', body: fd
    }).then(responseJSON);
  }

  function finalizeLarge(item, id) {
    var fd = new FormData();
    fd.append('csrf', csrf);
    fd.append('dir', root.getAttribute('data-dir') || '');
    fd.append('batch', '1');
    fd.append('upload_id', id);
    if (item.explicitPath) fd.append('path', item.path);
    else fd.append('paths', JSON.stringify([item.path]));
    return fetch(uploadForm.action, {
      method: 'POST', credentials: 'same-origin', body: fd
    }).then(responseJSON);
  }

  function disableUpload(on) {
    var controls = uploadForm.querySelectorAll('input, button');
    for (var i = 0; i < controls.length; i++) controls[i].disabled = on;
  }

  if (uploadForm && filesInput && dirInput && window.fetch
      && window.Promise && window.FormData) {
    uploadForm.addEventListener('submit', function (ev) {
      var items = selectedUploads();
      if (!items.length) return; // server renders the no-JS validation error

      var override = uploadPath
        ? (uploadPath.value || '').replace(/^\s+|\s+$/g, '') : '';
      if (override && items.length !== 1) {
        ev.preventDefault();
        uploadFlash('the path override can only be used with one file', 'err');
        return;
      }
      if (override) {
        items[0].path = override;
        items[0].explicitPath = true;
      }

      var transport = window.IczeliaUpload;
      if (!transport || !transport.uploadFile) return; // native fallback
      ev.preventDefault();
      disableUpload(true);

      // Keep multipart requests below the daemon/nginx request cap. A group
      // also has a file-count ceiling so thousands of tiny directory members
      // do not produce one enormous multipart parser workload.
      var nativeMax = transport.nativeSize || (6 * 1024 * 1024);
      var groupMax = 5 * 1024 * 1024;
      var groups = [];
      var group = [];
      var groupBytes = 0;
      function flushGroup() {
        if (!group.length) return;
        groups.push({ kind: 'small', items: group });
        group = [];
        groupBytes = 0;
      }
      for (var i = 0; i < items.length; i++) {
        var item = items[i];
        if (item.file.size > nativeMax) {
          flushGroup();
          groups.push({ kind: 'large', item: item });
        } else {
          if (group.length >= 100 || groupBytes + item.file.size > groupMax) {
            flushGroup();
          }
          group.push(item);
          groupBytes += item.file.size;
        }
      }
      flushGroup();

      var complete = 0;
      var chain = Promise.resolve();
      groups.forEach(function (task) {
        chain = chain.then(function () {
          if (task.kind === 'small') {
            uploadFlash('uploading ' + (complete + 1) + '-' +
              (complete + task.items.length) + ' of ' + items.length + '...');
            return postSmallGroup(task.items).then(function () {
              complete += task.items.length;
            });
          }

          var f = task.item.file;
          var id;
          uploadFlash('uploading ' + (complete + 1) + ' of ' + items.length
            + ': ' + task.item.path + ' (0%)');
          return transport.uploadFile(f, function (done, total) {
            var pct = total ? Math.floor(done * 100 / total) : 0;
            uploadFlash('uploading ' + (complete + 1) + ' of ' + items.length
              + ': ' + task.item.path + ' (' + pct + '%, '
              + transport.fmtSize(done) + ' / ' + transport.fmtSize(total) + ')');
          }).then(function (uploadId) {
            id = uploadId;
            uploadFlash('finalizing ' + task.item.path + '...');
            return finalizeLarge(task.item, id);
          }).then(function () {
            complete++;
          }).catch(function (err) {
            return transport.abort(id).then(function () { throw err; });
          });
        });
      });

      chain.then(function () {
        uploadFlash('uploaded ' + complete + ' file'
          + (complete === 1 ? '' : 's') + '; refreshing...', 'ok');
        window.location.reload();
      }).catch(function (err) {
        disableUpload(false);
        uploadFlash('upload stopped after ' + complete + ' file'
          + (complete === 1 ? '' : 's') + ': '
          + (err && err.message || err), 'err');
      });
    });
  }
})();
