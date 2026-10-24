/*
 * Godot WebUI - browser-side bridge client.
 *
 * Injected by the Android plugin before any page script runs, so `window.Godot` always exists
 * inside the overlay. Do not <script src> this file.
 *
 *   Godot.emit(name, payload?)        page -> Godot. name: /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/, payload: plain object.
 *   Godot.onState(name, fn)           Godot -> page, persistent state (GodotWebUI.set_state). fn(payload) is also
 *                                     called at once with the latest value if one already arrived.
 *   Godot.onEvent(name, fn)           Godot -> page, one-shot notification (GodotWebUI.emit_event). Never replayed.
 *   Godot.on(name, fn)                Same as onState (kept for compatibility).
 *   Godot.off(name, fn)               Removes a handler registered with on/onState/onEvent.
 *   Godot.guard(releaseFn)            releaseFn runs on blur / page hidden / app pause. Returns an unregister fn.
 *   Godot.onBack(fn)                  the Android Back button was pressed (needs GodotWebUI.handle_back_button).
 *                                     fn() returns true if the page used it (closed a panel, went to the previous
 *                                     screen); otherwise Godot gets GodotWebUI.back_requested. The newest handler
 *                                     is asked first. Returns an unregister function.
 *   Godot.touchRegions(selector?)     elements matching selector (default '[data-webui-touch]') receive touches;
 *                                     the rest of the screen passes through to the game (touch mode "regions").
 *   Godot.editText(options)           opens the keyboard-aware text editor (see below); returns {close()}.
 *   Godot.editText.attach(el, opts)   opens the editor from an existing field/button; writes the result back.
 *   Godot.available                   true when the native bridge is present.
 *   Godot.preview                     true in the desktop development preview (not Android).
 *
 * Godot.editText({ title, value, placeholder, mode, maxLength, confirmLabel, cancelLabel,
 *                   onConfirm(value), onCancel }) shows a compact editor pinned to the top of the
 * visible viewport, so the Android keyboard never covers the field or its buttons. mode: 'text'
 * (default), 'password', 'numeric' or 'multiline'. Enter/IME Done confirms (single line), Escape or
 * Android Back cancels, and callbacks fire exactly once. While the editor is open it consumes the
 * Android Back button. editText.attach(el, options) wires the same editor to an element: tapping it
 * opens the editor with the element's current value; confirming writes the value back (to .value
 * for inputs/textareas, else .textContent) before calling options.onConfirm.
 */
(function () {
  'use strict';
  if (window.Godot) return;

  var MAX_CHARS = 64 * 1024;
  var MAX_QUEUE = 256;
  var NAME_RE = /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/;

  var queue = [];
  var EVENT_PREFIX = '@e:';             // marks one-shot events sent by GodotWebUI.emit_event
  var listeners = Object.create(null);  // state listeners
  var eventListeners = Object.create(null);
  var last = Object.create(null);
  var guards = [];
  var backHandlers = [];
  var warnedMissing = false;

  // Android exposes window.GodotNative. The desktop development preview (WRY/WebView2) only has
  // window.ipc, so adapt it to the same one-string postMessage shape.
  var ipcAdapter = null;
  function native() {
    if (window.GodotNative) return window.GodotNative;
    if (window.ipc && typeof window.ipc.postMessage === 'function') {
      return ipcAdapter || (ipcAdapter = { postMessage: function (s) { window.ipc.postMessage(s); } });
    }
    return undefined;
  }

  function send(obj) {
    var text;
    try { text = JSON.stringify(obj); } catch (e) {
      console.error('[Godot] payload is not JSON serializable:', e.message);
      return false;
    }
    if (text.length > MAX_CHARS) {
      console.error('[Godot] message too large (' + text.length + ' chars, max ' + MAX_CHARS + ').');
      return false;
    }
    var n = native();
    if (!n) {
      if (!warnedMissing && document.readyState !== 'loading') {
        warnedMissing = true;
        console.warn('[Godot] native bridge unavailable; messages are not delivered (not running inside Godot WebUI?).');
      }
      if (queue.length < MAX_QUEUE) queue.push(text);
      return false;
    }
    n.postMessage(text);
    return true;
  }

  function flush() {
    var n = native();
    while (n && queue.length) n.postMessage(queue.shift());
  }

  function releaseAll(reason) {
    guards.slice().forEach(function (fn) {
      try { fn(reason); } catch (e) { console.error('[Godot] guard threw:', e); }
    });
  }

  var Godot = {
    get available() { return !!native(); },
    /** true when running in the desktop development preview instead of Android */
    get preview() { return !window.GodotNative && !!native(); },

    emit: function (name, payload) {
      if (typeof name !== 'string' || !NAME_RE.test(name)) {
        console.error('[Godot] invalid event name:', name);
        return false;
      }
      if (payload === undefined || payload === null) payload = {};
      if (typeof payload !== 'object' || Array.isArray(payload)) {
        console.error('[Godot] payload for "' + name + '" must be a plain object.');
        return false;
      }
      flush();
      return send({ t: 'event', name: name, payload: payload });
    },

    onState: function (name, fn) {
      if (typeof fn !== 'function') { console.error('[Godot] onState() needs a function.'); return; }
      (listeners[name] = listeners[name] || []).push(fn);
      if (name in last) {
        try { fn(last[name]); } catch (e) { console.error('[Godot] handler for "' + name + '" threw:', e); }
      }
    },

    onEvent: function (name, fn) {
      if (typeof fn !== 'function') { console.error('[Godot] onEvent() needs a function.'); return; }
      (eventListeners[name] = eventListeners[name] || []).push(fn);
    },

    on: function (name, fn) { Godot.onState(name, fn); },

    off: function (name, fn) {
      [listeners[name], eventListeners[name]].forEach(function (l) {
        var i = l ? l.indexOf(fn) : -1;
        if (i >= 0) l.splice(i, 1);
      });
    },

    guard: function (releaseFn) {
      guards.push(releaseFn);
      return function () {
        var i = guards.indexOf(releaseFn);
        if (i >= 0) guards.splice(i, 1);
      };
    },

    onBack: function (fn) {
      if (typeof fn !== 'function') { console.error('[Godot] onBack() needs a function.'); return function () {}; }
      backHandlers.push(fn);
      return function () {
        var i = backHandlers.indexOf(fn);
        if (i >= 0) backHandlers.splice(i, 1);
      };
    },

    touchRegions: function (selector) {
      regionSelector = selector || '[data-webui-touch]';
      // Tells GodotWebUI (touch mode AUTO) that this page wants pass-through for everything else.
      Godot.emit('webui.touch_regions', { selector: regionSelector });
      scheduleRegions(true);
    },

    // Keyboard-aware text editor; see the header comment for the options.
    // The real function (not a wrapper) so editText.attach below is reachable through Godot.
    editText: editText,

    // ---- called by native; not part of the public API
    __receive: function (name, json) {
      var value;
      try { value = JSON.parse(json); } catch (e) {
        console.error('[Godot] bad payload from Godot for "' + name + '":', e.message);
        return;
      }
      var isEvent = name.indexOf(EVENT_PREFIX) === 0;
      if (isEvent) name = name.slice(EVENT_PREFIX.length);
      else last[name] = value;  // only state is remembered for late subscribers
      ((isEvent ? eventListeners : listeners)[name] || []).slice().forEach(function (fn) {
        try { fn(value); } catch (e) { console.error('[Godot] handler for "' + name + '" threw:', e); }
      });
    },

    __lifecycle: function (state) {
      if (state === 'pause') releaseAll('pause');
    }
  };

  // ---- Back button: Godot asks, the newest handler that returns true consumes it, then Godot is told which.
  Godot.onEvent('webui.back', function () {
    var handled = false;
    for (var i = backHandlers.length - 1; i >= 0 && !handled; i--) {
      try { handled = backHandlers[i]() === true; } catch (e) { console.error('[Godot] onBack handler threw:', e); }
    }
    Godot.emit(handled ? 'webui.back_handled' : 'webui.back_unhandled');
  });

  // ---- stuck-input protection
  window.addEventListener('blur', function () { releaseAll('blur'); });
  window.addEventListener('pagehide', function () { releaseAll('pagehide'); });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) releaseAll('hidden');
  });

  // ---- keyboard-aware text editor ---------------------------------------------------------------
  // A small editor card pinned to the top of the visible viewport: on Android the soft keyboard
  // pans over the page (or, with interactive-widget=resizes-content, shrinks it), so a top-anchored
  // card and its action buttons always stay in view. One editor can be open at a time; while it
  // is open it consumes the Android Back button (cancel). Confirm/cancel callbacks fire once.

  var editorSession = null;

  function ensureEditorStyles() {
    if (document.getElementById('webui-textedit-style')) return;
    var s = document.createElement('style');
    s.id = 'webui-textedit-style';
    s.textContent = ''
      + '#webui-textedit{position:fixed;top:max(3vh,env(safe-area-inset-top));left:50%;'
      + 'transform:translateX(-50%);z-index:800;width:min(560px,92vw);padding:14px 16px 12px;'
      + 'border-radius:16px;background:var(--webui-te-panel,rgba(10,14,30,.96));'
      + 'border:1.5px solid var(--webui-te-border,rgba(244,238,222,.16));'
      + 'box-shadow:0 18px 50px rgba(0,0,0,.5);color:var(--webui-te-ink,#f2eddd);'
      + 'font-family:inherit;animation:webui-te-in .18s ease}'
      + '@keyframes webui-te-in{from{opacity:0;transform:translateX(-50%) translateY(-10px)}}'
      + '@media(prefers-reduced-motion:reduce){#webui-textedit{animation:none}}'
      + '#webui-textedit .webui-te-title{display:block;font-size:11px;letter-spacing:.26em;'
      + 'font-weight:800;opacity:.6;margin-bottom:8px;white-space:nowrap;overflow:hidden;'
      + 'text-overflow:ellipsis}'
      + '#webui-textedit .webui-te-field{width:100%;border:0;border-radius:10px;'
      + 'background:rgba(127,127,127,.14);color:inherit;font-family:inherit;font-size:16px;'
      + 'font-weight:600;line-height:1.4;padding:10px 12px;outline:none;box-sizing:border-box;'
      + 'resize:none;-webkit-appearance:none;appearance:none}'
      + '#webui-textedit .webui-te-field:focus{background:rgba(127,127,127,.2);'
      + 'box-shadow:inset 0 0 0 1.5px var(--webui-te-accent,#ffb84d)}'
      + '#webui-textedit .webui-te-count{font-size:10px;opacity:.5;text-align:right;margin-top:4px}'
      + '#webui-textedit .webui-te-row{display:flex;gap:8px;margin-top:10px}'
      + '#webui-textedit .webui-te-btn{flex:1;padding:10px 12px;border-radius:11px;font:inherit;'
      + 'font-weight:800;font-size:14px;transition:transform .12s ease}'
      + '#webui-textedit .webui-te-btn:active{transform:scale(.96)}'
      + '#webui-textedit .webui-te-ok{background:var(--webui-te-accent,#ffb84d);'
      + 'color:var(--webui-te-accent-ink,#221832)}'
      + '#webui-textedit .webui-te-no{background:rgba(127,127,127,.12);'
      + 'border:1.5px solid var(--webui-te-border,rgba(244,238,222,.16))}';
    document.head.appendChild(s);
  }

  function editText(options) {
    options = options || {};
    if (editorSession) editorSession.close();  // settle any previous editor as a cancel
    ensureEditorStyles();

    var mode = ['password', 'numeric', 'multiline'].indexOf(options.mode) >= 0 ? options.mode : 'text';
    var maxLength = Math.max(0, options.maxLength | 0);

    var root = document.createElement('div');
    root.id = 'webui-textedit';
    root.setAttribute('data-webui-touch', '');  // reachable in REGIONS pass-through mode
    var title = document.createElement('span');
    title.className = 'webui-te-title';
    title.textContent = options.title || 'Edit';
    root.appendChild(title);

    var field = document.createElement(mode === 'multiline' ? 'textarea' : 'input');
    field.className = 'webui-te-field';
    field.setAttribute('autocomplete', 'off');
    if (mode === 'numeric') {
      field.type = 'number';
      field.setAttribute('inputmode', 'decimal');
    } else {
      field.type = mode === 'password' ? 'password' : 'text';
    }
    var value = options.value == null ? '' : String(options.value);
    field.value = value;
    if (options.placeholder) field.placeholder = options.placeholder;
    if (maxLength) field.maxLength = maxLength;
    if (mode === 'multiline') field.rows = 3;
    root.appendChild(field);

    var counter = null;
    if (maxLength) {
      counter = document.createElement('span');
      counter.className = 'webui-te-count';
      counter.textContent = value.length + '/' + maxLength;
      root.appendChild(counter);
    }

    var row = document.createElement('div');
    row.className = 'webui-te-row';
    var btnCancel = document.createElement('button');
    btnCancel.type = 'button';
    btnCancel.className = 'webui-te-btn webui-te-no';
    btnCancel.setAttribute('data-webui-touch', '');
    btnCancel.textContent = options.cancelLabel || 'Cancel';
    var btnOk = document.createElement('button');
    btnOk.type = 'button';
    btnOk.className = 'webui-te-btn webui-te-ok';
    btnOk.setAttribute('data-webui-touch', '');
    btnOk.textContent = options.confirmLabel || 'Done';
    row.appendChild(btnCancel);
    row.appendChild(btnOk);
    root.appendChild(row);
    document.body.appendChild(root);

    var settled = false;
    var offBack = null;

    function settle(confirmed) {
      if (settled) return;
      settled = true;
      document.removeEventListener('keydown', onKey, true);
      if (window.visualViewport) {
        window.visualViewport.removeEventListener('resize', onViewport);
        window.visualViewport.removeEventListener('scroll', onViewport);
      }
      if (offBack) { offBack(); offBack = null; }
      try { field.blur(); } catch (e) { /* closing the keyboard is best effort */ }
      root.remove();
      editorSession = null;
      if (confirmed) {
        if (typeof options.onConfirm === 'function') options.onConfirm(field.value);
      } else if (typeof options.onCancel === 'function') {
        options.onCancel();
      }
    }

    function onKey(e) {
      if (e.key === 'Escape') {
        e.preventDefault();
        settle(false);
      } else if (e.key === 'Enter' && !e.isComposing) {
        if (mode !== 'multiline' || e.ctrlKey || e.metaKey) {
          e.preventDefault();
          settle(true);  // the IME Done action arrives as Enter
        }
      }
    }

    // Keep the card above the keyboard: with interactive-widget=resizes-content the layout
    // viewport shrinks and the fixed card follows; in pan fallbacks, shift it up manually.
    function onViewport() {
      var vv = window.visualViewport;
      if (!vv) return;
      var rect = root.getBoundingClientRect();
      var keyboardTop = (vv.height + vv.offsetTop) * (window.innerWidth / vv.width);
      var overflow = rect.bottom - keyboardTop;
      var shift = overflow > 0 ? Math.min(overflow, Math.max(rect.top - 8, 0)) : 0;
      root.style.transform = 'translateX(-50%) translateY(' + (-shift) + 'px)';
    }

    function onInput() {
      if (counter) counter.textContent = field.value.length + '/' + maxLength;
    }

    document.addEventListener('keydown', onKey, true);
    field.addEventListener('input', onInput);
    btnCancel.addEventListener('click', function () { settle(false); });
    btnOk.addEventListener('click', function () { settle(true); });
    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', onViewport);
      window.visualViewport.addEventListener('scroll', onViewport);
    }
    // While the editor is open it owns Android Back (newest onBack handler is asked first).
    if (typeof Godot.onBack === 'function') {
      offBack = Godot.onBack(function () { settle(false); return true; });
    }

    editorSession = {
      close: function (confirmed) { settle(!!confirmed); },
      focusField: function () {
        // Focus synchronously (inside the tap's user gesture, so Android shows the keyboard),
        // then select in the next frame.
        try { field.focus(); } catch (e) { /* ignore */ }
        requestAnimationFrame(function () {
          field.focus();
          if (field.value.length && field.setSelectionRange && field.type !== 'number') {
            field.setSelectionRange(0, field.value.length);  // typed-over rename, but adjustable
          }
        });
      }
    };
    editorSession.focusField();
    requestAnimationFrame(onViewport);
    return editorSession;
  }

  // Wire an existing element (input, textarea or button) to open the editor with its value.
  editText.attach = function (el, options) {
    if (typeof el === 'string') el = document.getElementById(el);
    if (!el) return;
    options = options || {};
    var isField = /^(INPUT|TEXTAREA)$/.test(el.tagName);
    if (isField) el.readOnly = true;  // the underlying field never opens the IME itself
    el.addEventListener('pointerdown', function (e) {
      e.preventDefault();
      var merged = {};
      for (var key in options) merged[key] = options[key];
      merged.value = isField ? el.value : el.textContent;
      var userConfirm = merged.onConfirm;
      merged.onConfirm = function (v) {
        if (isField) el.value = v;
        else el.textContent = v;
        if (typeof userConfirm === 'function') userConfirm(v);
      };
      editText(merged);
    });
  };

  // ---- touch regions (pass-through of everything else to the game)
  var regionSelector = null;
  var lastRegions = '';
  var regionTimer = 0;

  function computeRegions() {
    if (!regionSelector) return;
    var rects = [];
    document.querySelectorAll(regionSelector).forEach(function (el) {
      var r = el.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        rects.push(Math.round(r.left), Math.round(r.top), Math.round(r.right), Math.round(r.bottom));
      }
    });
    var key = rects.join(',');
    if (key !== lastRegions && send({ t: 'regions', rects: rects })) lastRegions = key;
  }

  function scheduleRegions(immediate) {
    if (immediate) computeRegions();
    if (!regionTimer) regionTimer = setInterval(computeRegions, 100);
  }

  // Scrolling and viewport changes (screen rotation, the soft keyboard) move region rectangles;
  // report the change on the next frame instead of waiting for the next poll.
  var scrollQueued = false;
  function queueRegions() {
    if (scrollQueued || !regionSelector) return;
    scrollQueued = true;
    requestAnimationFrame(function () {
      scrollQueued = false;
      computeRegions();
    });
  }

  function start() {
    window.addEventListener('resize', queueRegions);
    window.addEventListener('scroll', queueRegions, { capture: true, passive: true });
    if (window.visualViewport) {
      window.visualViewport.addEventListener('resize', queueRegions);
    }
    flush();
    send({ t: 'ready' });
    computeRegions();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();

  window.Godot = Godot;
})();
