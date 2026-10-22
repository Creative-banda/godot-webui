/*
 * Godot WebUI - browser-side bridge client.
 *
 * Injected by the Android plugin before any page script runs, so `window.Godot` always exists
 * inside the overlay. Do not <script src> this file.
 *
 *   Godot.emit(name, payload?)        page -> Godot. name: /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/, payload: plain object.
 *   Godot.on(name, fn)                Godot -> page. fn(payload). Replays the last value if one already arrived.
 *   Godot.off(name, fn)
 *   Godot.guard(releaseFn)            releaseFn runs on blur / page hidden / app pause. Returns an unregister fn.
 *   Godot.touchRegions(selector?)     elements matching selector (default '[data-webui-touch]') receive touches;
 *                                     the rest of the screen passes through to the game (touch mode "regions").
 *   Godot.available                   true when the native bridge is present.
 */
(function () {
  'use strict';
  if (window.Godot) return;

  var MAX_CHARS = 64 * 1024;
  var MAX_QUEUE = 256;
  var NAME_RE = /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/;

  var queue = [];
  var listeners = Object.create(null);
  var last = Object.create(null);
  var guards = [];
  var warnedMissing = false;

  function native() { return window.GodotNative; }

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

    on: function (name, fn) {
      if (typeof fn !== 'function') { console.error('[Godot] on() needs a function.'); return; }
      (listeners[name] = listeners[name] || []).push(fn);
      if (name in last) {
        try { fn(last[name]); } catch (e) { console.error('[Godot] handler for "' + name + '" threw:', e); }
      }
    },

    off: function (name, fn) {
      var l = listeners[name];
      if (!l) return;
      var i = l.indexOf(fn);
      if (i >= 0) l.splice(i, 1);
    },

    guard: function (releaseFn) {
      guards.push(releaseFn);
      return function () {
        var i = guards.indexOf(releaseFn);
        if (i >= 0) guards.splice(i, 1);
      };
    },

    touchRegions: function (selector) {
      regionSelector = selector || '[data-webui-touch]';
      scheduleRegions(true);
    },

    // ---- called by native; not part of the public API
    __receive: function (name, json) {
      var value;
      try { value = JSON.parse(json); } catch (e) {
        console.error('[Godot] bad payload from Godot for "' + name + '":', e.message);
        return;
      }
      last[name] = value;
      (listeners[name] || []).slice().forEach(function (fn) {
        try { fn(value); } catch (e) { console.error('[Godot] handler for "' + name + '" threw:', e); }
      });
    },

    __lifecycle: function (state) {
      if (state === 'pause') releaseAll('pause');
    }
  };

  // ---- stuck-input protection
  window.addEventListener('blur', function () { releaseAll('blur'); });
  window.addEventListener('pagehide', function () { releaseAll('pagehide'); });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) releaseAll('hidden');
  });

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
    if (!regionTimer) regionTimer = setInterval(computeRegions, 200);
  }

  function start() {
    window.addEventListener('resize', function () { computeRegions(); });
    flush();
    send({ t: 'ready' });
    computeRegions();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();

  window.Godot = Godot;
})();
