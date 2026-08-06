// iczelia.net - personal CMS chunked upload glue.
//
// Forms tagged with data-cms-upload="<name>" get their <input
// type="file" name="<name>"> intercepted on submit. The file is sliced
// into 2 MB chunks and POSTed to /admin/upload/chunk; the assembled
// upload_id is then injected as a hidden field and the form continues
// to its real action (subpages/new, subpages/:id/rezip, backup/import,
// etc.). Anything inside the request-cap (<= 6 MB) falls through to
// the normal multipart submission so the JS path is purely additive.
//
// No bundlers, no async/await: keeps working on every browser that
// also supports fetch + Blob.slice (i.e. anything since 2017).

(function () {
  'use strict';

  var CHUNK_SIZE      = 2 * 1024 * 1024;  // 2 MB per POST
  var NATIVE_SIZE_OK  = 6 * 1024 * 1024;  // below this, just let the form post
  var CHUNK_RETRIES   = 4;

  function supported() {
    return document.querySelector
        && document.querySelectorAll
        && document.addEventListener
        && window.fetch
        && window.Promise
        && window.FormData;
  }

  function csrfToken() {
    var m = document.querySelector('meta[name="cms-upload-csrf"]');
    return m ? m.getAttribute('content') : '';
  }

  function ensureProgress(form) {
    var p = form.querySelector('.cms-upload-progress');
    if (!p) {
      p = document.createElement('p');
      p.className = 'cms-upload-progress';
      p.style.cssText = 'font-size:12px;color:#555;margin:0.5em 0;';
      form.appendChild(p);
    }
    return p;
  }

  function setProgress(p, msg) { p.textContent = msg; }

  function fmtSize(n) {
    if (n < 1024)       return n + ' B';
    if (n < 1048576)    return (n / 1024).toFixed(1) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(1) + ' MB';
    return (n / 1073741824).toFixed(2) + ' GB';
  }

  function postJSON(url, opts) {
    opts = opts || {};
    opts.credentials = 'same-origin';
    opts.method = 'POST';
    return fetch(url, opts).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) {
          var e = new Error(j && j.error ? j.error : 'http ' + r.status);
          e.httpStatus = r.status;
          throw e;
        }
        return j;
      }, function () {
        var e = new Error('non-json response (http ' + r.status + ')');
        e.httpStatus = r.status;
        throw e;
      });
    });
  }

  function init(filename) {
    var fd = new FormData();
    fd.append('csrf', csrfToken());
    if (filename) fd.append('filename', filename);
    return postJSON('/admin/upload/init', { body: fd });
  }

  function postChunk(id, offset, blob) {
    var url = '/admin/upload/chunk?id=' + encodeURIComponent(id)
            + '&offset=' + offset
            + '&csrf=' + encodeURIComponent(csrfToken());
    var attempt = 0;
    function send() {
      return postJSON(url, {
        headers: { 'Content-Type': 'application/octet-stream' },
        body: blob,
      }).catch(function (err) {
        var status = err && err.httpStatus;
        var transient = !status || status === 408 || status === 429
          || status === 502 || status === 503 || status === 504;
        if (!transient || attempt >= CHUNK_RETRIES) throw err;
        var delay = 250 * Math.pow(2, attempt++);
        return new Promise(function (resolve) {
          window.setTimeout(resolve, delay);
        }).then(send);
      });
    }
    return send();
  }

  function abort(id) {
    if (!id) return Promise.resolve();
    var fd = new FormData();
    fd.append('csrf', csrfToken());
    fd.append('id', id);
    return fetch('/admin/upload/abort', {
      method: 'POST', body: fd, credentials: 'same-origin',
    }).catch(function () { /* best effort */ });
  }

  // Upload sequentially, one chunk at a time. Returns a promise that
  // resolves with the upload id when the last chunk lands.
  function uploadFile(file, onProgress) {
    return init(file.name).then(function (j) {
      var id = j.id;
      var total = file.size;
      var offset = 0;
      var slicer = file.slice || file.webkitSlice || file.mozSlice;
      function next() {
        if (offset >= total) return id;
        var end = Math.min(offset + CHUNK_SIZE, total);
        var blob = slicer.call(file, offset, end);
        return postChunk(id, offset, blob).then(function (r) {
          offset = r.size;
          if (onProgress) onProgress(offset, total);
          return next();
        });
      }
      return Promise.resolve(next()).catch(function (e) {
        return abort(id).then(function () { throw e; });
      });
    });
  }

  function fileInputFor(form) {
    var name = form.getAttribute('data-cms-upload');
    if (!name) return null;
    return form.querySelector('input[type="file"][name="' + name + '"]');
  }

  function disableSubmit(form, on) {
    var btns = form.querySelectorAll('button, input[type="submit"]');
    for (var i = 0; i < btns.length; i++) btns[i].disabled = on;
  }

  function attach(form) {
    if (form._cmsUploadBound) return;
    form._cmsUploadBound = true;
    form.addEventListener('submit', function (ev) {
      var input = fileInputFor(form);
      if (!input || !input.files || !input.files[0]) return;
      var file = input.files[0];
      var slicer = file.slice || file.webkitSlice || file.mozSlice;
      if (!slicer) return;
      if (file.size <= NATIVE_SIZE_OK) return;  // small enough: native submit
      ev.preventDefault();

      var p = ensureProgress(form);
      disableSubmit(form, true);
      setProgress(p,
        'uploading 0 / ' + fmtSize(file.size) + ' (0%)');

      uploadFile(file, function (done, total) {
        var pct = total ? Math.floor(done * 100 / total) : 0;
        setProgress(p,
          'uploading ' + fmtSize(done) + ' / ' + fmtSize(total)
          + ' (' + pct + '%)');
      }).then(function (id) {
        setProgress(p,
          'uploaded ' + fmtSize(file.size) + '; finishing...');
        // Replace the file input with a hidden upload_id field and
        // resubmit. We disable the file input first so the form's
        // multipart payload no longer includes the 4 GB blob.
        input.disabled = true;
        var hid = document.createElement('input');
        hid.type = 'hidden';
        hid.name = 'upload_id';
        hid.value = id;
        form.appendChild(hid);
        disableSubmit(form, false);
        // Use HTMLFormElement.submit() to bypass our own listener.
        form.submit();
      }).catch(function (err) {
        disableSubmit(form, false);
        setProgress(p, 'upload failed: ' + (err && err.message || err));
      });
    });
  }

  function init_all() {
    var forms = document.querySelectorAll('form[data-cms-upload]');
    for (var i = 0; i < forms.length; i++) attach(forms[i]);
  }

  // The subpage directory uploader reuses the same resumable transport for
  // individual members that are too large for a normal multipart request.
  window.IczeliaUpload = {
    uploadFile: uploadFile,
    abort: abort,
    fmtSize: fmtSize,
    nativeSize: NATIVE_SIZE_OK
  };

  if (!supported()) return;

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init_all);
  } else {
    init_all();
  }
})();
