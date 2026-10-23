/*
 * Godot WebUI - edit mode (development only).
 *
 * Injected after godot.js into the desktop PREVIEW copy of a page when the editor's visual editor
 * runs it; never part of an Android export or of the staged Android files. It lets the editor
 * select an element, read its computed style and the stylesheet rules that apply to it, and apply
 * a changed declaration live to the rule it came from (the same rule the editor then patches in the
 * source file). It talks through the normal bridge with one event name, `webui_edit`:
 *
 *   page -> Godot  {op:'ready'}
 *                  {op:'selected', ...}     see selection() below
 *                  {op:'cleared'}
 *                  {op:'apply_result', ok, error?, file, path, prop, value}
 *   Godot -> page  {op:'enable', on}        turn selection on/off (on by default)
 *                  {op:'select', selector}  select by a selector reported earlier
 *                  {op:'apply', file, path, selector, prop, value}   value '' removes the declaration
 *
 * While selection is on, clicks are swallowed so the page's own buttons do not fire.
 */
(function () {
  'use strict';
  if (window.__webuiEdit || !window.Godot) return;

  var EVENT = 'webui_edit';
  var UI_ID = 'webui-edit-ui';
  var PROPS = [
    'font-size', 'font-weight', 'color', 'background-color', 'text-align',
    'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
    'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
    'width', 'height', 'border-top-width', 'border-style', 'border-color', 'border-radius',
    'display', 'flex-direction', 'justify-content', 'align-items', 'gap',
  ];
  var BLOCKED = ['pointerdown', 'pointerup', 'pointercancel', 'mousedown', 'mouseup', 'touchstart', 'touchend', 'touchmove', 'click', 'dblclick', 'contextmenu'];

  var enabled = true;
  var selected = null;
  var hoverBox, selectBox, root;

  // ---------------------------------------------------------------- selection overlay

  function buildOverlay() {
    root = document.createElement('div');
    root.id = UI_ID;
    root.style.cssText = 'position:fixed;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none';
    hoverBox = box('1px dashed #4cc2ff', 'rgba(76,194,255,0.10)');
    selectBox = box('2px solid #ff9f1c', 'rgba(255,159,28,0.12)');
    root.appendChild(hoverBox);
    root.appendChild(selectBox);
    document.documentElement.appendChild(root);
  }

  function box(border, fill) {
    var b = document.createElement('div');
    b.style.cssText = 'position:fixed;display:none;box-sizing:border-box;pointer-events:none;border:' + border + ';background:' + fill;
    return b;
  }

  function place(b, el) {
    if (!el || !el.isConnected) { b.style.display = 'none'; return; }
    var r = el.getBoundingClientRect();
    b.style.display = 'block';
    b.style.left = r.left + 'px';
    b.style.top = r.top + 'px';
    b.style.width = r.width + 'px';
    b.style.height = r.height + 'px';
  }

  function tick() {
    place(selectBox, selected);
    requestAnimationFrame(tick);
  }

  function isOurs(el) { return !!(el && el.closest && el.closest('#' + UI_ID)); }

  // ---------------------------------------------------------------- selectors

  function cssPath(el) {
    var parts = [];
    while (el && el.nodeType === 1 && el !== document.documentElement) {
      if (el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) {
        parts.unshift('#' + CSS.escape(el.id));
        break;
      }
      var part = el.tagName.toLowerCase();
      var parent = el.parentElement;
      if (parent) {
        var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
      }
      parts.unshift(part);
      el = parent;
    }
    return parts.join(' > ');
  }

  // Split a selector list at top-level commas.
  function splitList(text) {
    var out = [], depth = 0, quote = '', cur = '';
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (quote) { cur += c; if (c === '\\') { cur += text[++i] || ''; } else if (c === quote) quote = ''; continue; }
      if (c === '"' || c === "'") { quote = c; cur += c; continue; }
      if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') depth--;
      if (c === ',' && depth === 0) { out.push(cur.trim()); cur = ''; } else cur += c;
    }
    if (cur.trim()) out.push(cur.trim());
    return out;
  }

  // Approximate specificity of one complex selector (a*10000 + b*100 + c). Good enough to rank the
  // handful of rules that match one element; the browser stays the authority on the real cascade.
  function specificity(sel) {
    var s = sel.replace(/"[^"]*"|'[^']*'/g, '""').replace(/\[[^\]]*\]/g, ' [a] ');
    var a = (s.match(/#[\w-]+/g) || []).length;
    var b = (s.match(/\.[\w-]+/g) || []).length + (s.match(/\[a\]/g) || []).length + (s.match(/:(?!:)[\w-]+/g) || []).length;
    var c = (s.match(/::[\w-]+/g) || []).length;
    var types = s.replace(/[#.:][\w-]+/g, ' ').replace(/\[a\]/g, ' ').split(/[\s>+~(),]+/).filter(function (t) { return /^[a-zA-Z][\w-]*$/.test(t); });
    return a * 10000 + b * 100 + c + types.length;
  }

  function matchingSpecificity(rule, el) {
    var best = -1;
    splitList(rule.selectorText).forEach(function (part) {
      try { if (el.matches(part)) best = Math.max(best, specificity(part)); } catch (e) { /* pseudo-elements etc. */ }
    });
    return best;
  }

  // ---------------------------------------------------------------- stylesheets

  function pageBase() { return new URL('.', document.baseURI).href; }

  function relativeHref(sheet) {
    if (!sheet.href) return '';
    var base = pageBase();
    return sheet.href.indexOf(base) === 0 ? decodeURIComponent(sheet.href.slice(base.length).split('?')[0]) : '';
  }

  function appliesHere(rule) {
    if (rule.type === CSSRule.MEDIA_RULE) return window.matchMedia(rule.media.mediaText).matches;
    if (rule.type === CSSRule.SUPPORTS_RULE) return CSS.supports(rule.conditionText);
    return rule.constructor.name === 'CSSLayerBlockRule';
  }

  // Visits every style rule of every readable sheet in document order.
  function eachStyleRule(visit) {
    var order = 0;
    function walk(rules, sheet, path, conditions) {
      for (var i = 0; i < rules.length; i++) {
        var rule = rules[i];
        var here = path.concat(i);
        if (rule.type === CSSRule.STYLE_RULE) {
          visit(rule, sheet, here, conditions, order++);
        } else if (rule.cssRules && appliesHere(rule)) {
          var label = rule.type === CSSRule.MEDIA_RULE ? '@media ' + rule.media.mediaText : (rule.conditionText ? '@supports ' + rule.conditionText : '@layer');
          walk(rule.cssRules, sheet, here, conditions.concat(label));
        }
      }
    }
    Array.prototype.forEach.call(document.styleSheets, function (sheet) {
      if (sheet.ownerNode && isOurs(sheet.ownerNode)) return;
      var rules;
      try { rules = sheet.cssRules; } catch (e) { return; }  // cross-origin sheet
      walk(rules, sheet, [], []);
    });
  }

  function findRule(file, path, selector) {
    var found = null;
    eachStyleRule(function (rule, sheet, p) {
      if (found || relativeHref(sheet) !== file || p.join('.') !== path.join('.')) return;
      found = rule;
    });
    return found;
  }

  // ---------------------------------------------------------------- reporting

  function selection(el) {
    var cs = getComputedStyle(el);
    var computed = {};
    PROPS.forEach(function (p) { computed[p] = cs.getPropertyValue(p); });

    var rules = [];
    eachStyleRule(function (rule, sheet, path, conditions, order) {
      var spec = matchingSpecificity(rule, el);
      if (spec < 0) return;
      var declared = {};
      PROPS.forEach(function (p) {
        var v = rule.style.getPropertyValue(p);
        if (v) declared[p] = { value: v, important: rule.style.getPropertyPriority(p) === 'important' };
      });
      rules.push({
        file: relativeHref(sheet), inline: !sheet.href, path: path, selector: rule.selectorText,
        conditions: conditions, specificity: spec, order: order, declared: declared,
      });
    });

    function rank(a, b) { return a.specificity - b.specificity || a.order - b.order; }
    var targets = {};
    PROPS.forEach(function (p) {
      var best = -1;
      rules.forEach(function (r, i) {
        if (!(p in r.declared)) return;
        if (best === -1) { best = i; return; }
        var cur = rules[best];
        var ai = r.declared[p].important, bi = cur.declared[p].important;
        if (ai !== bi ? ai : rank(r, cur) > 0) best = i;
      });
      targets[p] = best;
    });
    // Where a property nobody declares yet should go: the most specific rule that lives in a file.
    // Rules ending in a bare `*` (layout wrappers such as `.screen.active > *`) are a last resort.
    var fallback = -1;
    [false, true].forEach(function (allowWildcard) {
      if (fallback !== -1) return;
      rules.forEach(function (r, i) {
        if (!r.file || (!allowWildcard && /\*\s*$/.test(r.selector))) return;
        if (fallback === -1 || rank(r, rules[fallback]) > 0) fallback = i;
      });
    });

    var r = el.getBoundingClientRect();
    return {
      op: 'selected', selector: cssPath(el), tag: el.tagName.toLowerCase(), id: el.id || '',
      classes: Array.prototype.slice.call(el.classList), text: (el.textContent || '').trim().slice(0, 40),
      rect: { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) },
      computed: computed, inline_style: el.getAttribute('style') || '',
      rules: rules, targets: targets, fallback: fallback,
    };
  }

  function emit(payload) { window.Godot.emit(EVENT, payload); }

  function select(el) {
    selected = el;
    if (!el) { emit({ op: 'cleared' }); return; }
    emit(selection(el));
  }

  // ---------------------------------------------------------------- applying

  function normalize(sel) { return (sel || '').replace(/["']/g, '').replace(/\s+/g, '').toLowerCase(); }

  function apply(msg) {
    var result = { op: 'apply_result', ok: false, file: msg.file, path: msg.path, prop: msg.prop, value: msg.value };
    var rule = findRule(msg.file, msg.path || []);
    if (!rule) { result.error = 'rule_not_found'; return emit(result); }
    if (normalize(rule.selectorText) !== normalize(msg.selector)) { result.error = 'selector_mismatch'; return emit(result); }
    if (msg.value !== '' && !CSS.supports(msg.prop, msg.value)) { result.error = 'invalid_value'; return emit(result); }
    rule.style.setProperty(msg.prop, msg.value, rule.style.getPropertyPriority(msg.prop));
    result.ok = true;
    emit(result);
    if (selected) emit(selection(selected));
  }

  // ---------------------------------------------------------------- wiring

  function start() {
    buildOverlay();
    BLOCKED.forEach(function (name) {
      document.addEventListener(name, function (e) {
        if (!enabled || isOurs(e.target)) return;
        e.stopImmediatePropagation();
        if (e.cancelable) e.preventDefault();
        if (name === 'click') select(e.target);
      }, true);
    });
    document.addEventListener('pointermove', function (e) {
      if (enabled && !isOurs(e.target)) place(hoverBox, e.target);
    }, true);
    document.addEventListener('pointerleave', function () { hoverBox.style.display = 'none'; }, true);

    window.Godot.onEvent(EVENT, function (msg) {
      if (!msg || typeof msg !== 'object') return;
      if (msg.op === 'enable') {
        enabled = !!msg.on;
        if (!enabled) { hoverBox.style.display = 'none'; }
      } else if (msg.op === 'select') {
        var el = null;
        try { el = document.querySelector(msg.selector); } catch (e) { /* invalid selector */ }
        select(el);
      } else if (msg.op === 'apply') {
        apply(msg);
      }
    });
    requestAnimationFrame(tick);
    emit({ op: 'ready' });
  }

  window.__webuiEdit = { select: select, selection: selection, enable: function (on) { enabled = !!on; } };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
