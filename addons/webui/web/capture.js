/*
 * Godot WebUI - preview capture (development only).
 *
 * Injected after godot.js into the desktop PREVIEW copy of a page by webui_preview_capture.gd, the
 * separate program that makes the picture a WebUIScreen node shows in the 2D editor. Never part of the
 * original HTML, an Android export or the game.
 *
 * It draws the page into a PNG without a screenshot: the live DOM (with the state the page is in right now)
 * is copied, every stylesheet, image and font it uses is embedded as a data URL, and the copy is rendered as
 * an SVG <foreignObject> onto a canvas. The result is sent back over the normal bridge in chunks:
 *
 *   Godot -> page  event "webui_capture_run"  {w, h}   size of the picture in CSS pixels (the project viewport)
 *   page -> Godot  event "webui_capture"       {t: 'meta', notes, w, h} | {t: 'chunk', n, data} | {t: 'done', chunks} | {t: 'error', text}
 *
 * What it cannot draw is reported in `notes`: canvases are copied as they are at this moment, but videos
 * without a decoded frame, iframes, plugins, assets that fail to load or are too large, and external
 * @import rules are left out. Animations and transitions are shown in their resting state. Scroll positions,
 * hover and focus states are not reproduced. This is a picture of the page, not the Android rendering.
 */
(function () {
  'use strict';
  if (window.__webuiCapture || !window.Godot) return;

  var EVENT = 'webui_capture';
  var CHUNK = 40000;                    // base64 characters per bridge message (the limit is 64 KB)
  var MAX_ASSET = 8 * 1024 * 1024;
  var MAX_TOTAL = 48 * 1024 * 1024;
  var RENDER_TIMEOUT_MS = 20000;
  var DATA_URL_LIMIT = 1500000;

  var notes = [];
  var total = 0;
  var cache = {};

  function note(text) { if (notes.indexOf(text) < 0 && notes.length < 12) notes.push(text); }
  function emit(payload) { window.Godot.emit(EVENT, payload); }

  // ---------------------------------------------------------------- embedding assets

  function toDataUrl(url) {
    if (cache[url]) return cache[url];
    cache[url] = fetch(url).then(function (r) {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.blob();
    }).then(function (blob) {
      total += blob.size;
      if (blob.size > MAX_ASSET || total > MAX_TOTAL) throw new Error('too large');
      return new Promise(function (resolve, reject) {
        var reader = new FileReader();
        reader.onload = function () { resolve(reader.result); };
        reader.onerror = reject;
        reader.readAsDataURL(blob);
      });
    });
    return cache[url];
  }

  function replaceAsync(text, regex, fn) {
    var matches = [];
    var m;
    regex.lastIndex = 0;
    while ((m = regex.exec(text)) !== null) matches.push({ index: m.index, length: m[0].length, groups: m });
    return Promise.all(matches.map(function (x) { return fn(x.groups); })).then(function (results) {
      var out = '';
      var last = 0;
      matches.forEach(function (x, i) { out += text.slice(last, x.index) + results[i]; last = x.index + x.length; });
      return out + text.slice(last);
    });
  }

  // url(...) in CSS: the SVG the page is drawn into cannot load files, so every asset is embedded.
  function inlineCss(css, base) {
    return replaceAsync(css, /url\(\s*(['"]?)([^)'"]*?)\1\s*\)/g, function (m) {
      var ref = m[2].trim();
      if (!ref || ref.charAt(0) === '#' || /^data:/i.test(ref)) return m[0];
      var abs;
      try { abs = new URL(ref, base).href; } catch (e) { note('unreadable url() ' + ref.slice(0, 40)); return m[0]; }
      return toDataUrl(abs).then(function (data) { return 'url("' + data + '")'; }, function () {
        note('not embedded: ' + ref.slice(0, 50));
        return 'none';
      });
    }).then(function (out) {
      if (/@import/i.test(out)) note('@import rules are not followed');
      return out;
    });
  }

  function copyBox(from, to) {
    ['id', 'class', 'style', 'width', 'height'].forEach(function (name) {
      if (from.hasAttribute(name)) to.setAttribute(name, from.getAttribute(name));
    });
  }

  // ---------------------------------------------------------------- the copy of the page

  async function build(w, h) {
    var clone = document.documentElement.cloneNode(true);

    clone.querySelectorAll('script, noscript, base').forEach(function (el) { el.remove(); });

    // Canvases and videos keep their pixels in memory, not in the DOM: copy what they show now.
    var origCanvases = document.querySelectorAll('canvas');
    clone.querySelectorAll('canvas').forEach(function (el, i) {
      var img = document.createElement('img');
      try {
        img.setAttribute('src', origCanvases[i].toDataURL('image/png'));
        copyBox(el, img);
        if (!img.hasAttribute('width') && origCanvases[i].width) img.setAttribute('width', origCanvases[i].width);
        if (!img.hasAttribute('height') && origCanvases[i].height) img.setAttribute('height', origCanvases[i].height);
        el.replaceWith(img);
      } catch (e) { note('a canvas could not be read'); el.remove(); }
    });
    var origVideos = document.querySelectorAll('video');
    clone.querySelectorAll('video').forEach(function (el, i) {
      var v = origVideos[i];
      if (v && v.readyState >= 2 && v.videoWidth) {
        try {
          var c = document.createElement('canvas');
          c.width = v.videoWidth; c.height = v.videoHeight;
          c.getContext('2d').drawImage(v, 0, 0);
          var img = document.createElement('img');
          img.setAttribute('src', c.toDataURL('image/png'));
          copyBox(el, img);
          el.replaceWith(img);
          return;
        } catch (e) { /* fall through */ }
      }
      note('a video has no picture to show');
      el.remove();
    });
    clone.querySelectorAll('iframe, embed, object').forEach(function (el) { note('<' + el.tagName.toLowerCase() + '> is not drawn'); el.remove(); });
    clone.querySelectorAll('audio').forEach(function (el) { el.remove(); });

    // Form state lives in properties, not attributes.
    var origFields = document.querySelectorAll('input, textarea, select');
    clone.querySelectorAll('input, textarea, select').forEach(function (el, i) {
      var f = origFields[i];
      if (!f) return;
      if (el.tagName === 'INPUT') {
        el.setAttribute('value', f.value);
        if (f.checked) el.setAttribute('checked', ''); else el.removeAttribute('checked');
      } else if (el.tagName === 'TEXTAREA') {
        el.textContent = f.value;
      } else {
        Array.prototype.forEach.call(el.options, function (opt, j) {
          if (f.options[j] && f.options[j].selected) opt.setAttribute('selected', ''); else opt.removeAttribute('selected');
        });
      }
    });

    var jobs = [];

    clone.querySelectorAll('link[rel~=stylesheet]').forEach(function (link) {
      var href = link.href || link.getAttribute('href');
      jobs.push(fetch(href).then(function (r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.text(); }).then(function (css) {
        return inlineCss(css, href);
      }).then(function (css) {
        var style = document.createElement('style');
        style.textContent = css;
        link.replaceWith(style);
      }, function () { note('stylesheet not loaded: ' + (link.getAttribute('href') || '').slice(0, 50)); link.remove(); }));
    });
    clone.querySelectorAll('link:not([rel~=stylesheet])').forEach(function (link) { link.remove(); });
    clone.querySelectorAll('style').forEach(function (style) {
      jobs.push(inlineCss(style.textContent, document.baseURI).then(function (css) { style.textContent = css; }));
    });
    clone.querySelectorAll('[style*="url("]').forEach(function (el) {
      jobs.push(inlineCss(el.getAttribute('style'), document.baseURI).then(function (css) { el.setAttribute('style', css); }));
    });
    clone.querySelectorAll('img').forEach(function (img) {
      var src = img.getAttribute('src') || '';
      img.removeAttribute('srcset');
      if (!src || /^data:/i.test(src)) return;
      jobs.push(toDataUrl(new URL(src, document.baseURI).href).then(function (data) { img.setAttribute('src', data); }, function () {
        note('image not embedded: ' + src.slice(0, 50));
        img.removeAttribute('src');
      }));
    });
    clone.querySelectorAll('image').forEach(function (img) {
      var ref = img.getAttribute('href') || img.getAttribute('xlink:href') || '';
      if (!ref || /^data:/i.test(ref)) return;
      jobs.push(toDataUrl(new URL(ref, document.baseURI).href).then(function (data) {
        img.setAttribute('href', data);
        img.removeAttribute('xlink:href');
      }, function () { note('svg image not embedded: ' + ref.slice(0, 50)); }));
    });
    clone.querySelectorAll('use').forEach(function (use) {
      var ref = use.getAttribute('href') || use.getAttribute('xlink:href') || '';
      if (ref && ref.charAt(0) !== '#') note('an svg <use> of another file is not drawn');
    });

    await Promise.all(jobs);

    var running = document.getAnimations ? document.getAnimations().length : 0;
    if (running) note(running + ' animation' + (running === 1 ? '' : 's') + ' shown at rest');

    // A still picture: finished states, no motion.
    var still = document.createElement('style');
    still.textContent = '*, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; }';
    (clone.querySelector('head') || clone).appendChild(still);
    clone.style.width = w + 'px';
    clone.style.height = h + 'px';
    clone.style.overflow = 'hidden';
    return new XMLSerializer().serializeToString(clone);
  }

  function render(html, w, h) {
    var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '">' +
      '<foreignObject x="0" y="0" width="' + w + '" height="' + h + '">' + html + '</foreignObject></svg>';
    var url = svg.length < DATA_URL_LIMIT
      ? 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg)
      : URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml;charset=utf-8' }));
    return new Promise(function (resolve, reject) {
      var img = new Image();
      var timer = setTimeout(function () { reject(new Error('the page could not be rendered in time')); }, RENDER_TIMEOUT_MS);
      img.onload = function () { clearTimeout(timer); resolve(img); };
      img.onerror = function () { clearTimeout(timer); reject(new Error('the browser could not render the copy of the page')); };
      img.src = url;
    }).then(function (img) {
      var canvas = document.createElement('canvas');
      canvas.width = w;
      canvas.height = h;
      canvas.getContext('2d').drawImage(img, 0, 0);
      return canvas.toDataURL('image/png');  // throws when the canvas is tainted
    });
  }

  async function run(w, h) {
    try {
      w = Math.max(16, Math.min(8192, Math.round(w)));
      h = Math.max(16, Math.min(8192, Math.round(h)));
      if (document.fonts && document.fonts.ready) await document.fonts.ready;
      var html = await build(w, h);
      var url = await render(html, w, h);
      var b64 = url.split(',')[1] || '';
      if (!b64) throw new Error('the picture is empty');
      emit({ t: 'meta', notes: notes, w: w, h: h });
      var count = 0;
      for (var i = 0; i < b64.length; i += CHUNK, count++) emit({ t: 'chunk', n: count, data: b64.slice(i, i + CHUNK) });
      emit({ t: 'done', chunks: count });
    } catch (e) {
      emit({ t: 'error', text: String(e && e.message ? e.message : e) });
    }
  }

  window.__webuiCapture = { run: run };
  window.Godot.onEvent('webui_capture_run', function (msg) { run(Number(msg && msg.w) || 1280, Number(msg && msg.h) || 720); });
})();
