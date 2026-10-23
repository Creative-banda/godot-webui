/*
 * Godot WebUI - edit mode (development only).
 *
 * Injected after godot.js into the desktop PREVIEW copy of a page when the editor's visual editor
 * runs it; never part of an Android export or of the staged Android files. It lets the editor
 * select an element and inspect it (what kind of element it is, its attributes and text, computed
 * style, the stylesheet rules that apply and where they live, what is inherited), and it applies a
 * change live to the rule it will be saved in. Every change is checked: after it is applied the
 * element's computed value must be what the new value would give, otherwise something with higher
 * priority overrides it and the change is undone and reported (`ineffective`). The editor patches the
 * source files itself. It talks through the normal bridge with one event name, `webui_edit`:
 *
 *   page -> Godot  {op:'ready'}
 *                  {op:'selected', ...}      see selection() below
 *                  {op:'cleared'}
 *                  {op:'apply_result', ok, error?, ...}    answer to apply
 *                  {op:'rule_result', ok, ...}             answer to add_rule / remove_rule
 *                  {op:'content_result', ok, ...}          answer to apply_text / apply_attr
 *   Godot -> page  {op:'config', props}      which properties to report (key -> {read, write, detect, inherited})
 *                  {op:'enable', on}         turn selection on/off (on by default)
 *                  {op:'select', selector | x, y}   select by a selector reported earlier, or the element at a point
 *                  {op:'apply', file, path, selector, prop, value}     value '' removes the declaration
 *                  {op:'add_rule', file, selector, decls}              new rule at the end of a stylesheet
 *                  {op:'remove_rule', file, path, selector}
 *                  {op:'apply_text', text, selector?} / {op:'apply_attr', name, value}   selector: an element inside the selected one; value null removes an attribute
 *
 * While selection is on, clicks are swallowed so the page's own buttons do not fire.
 */
(function () {
  'use strict';
  if (window.__webuiEdit || !window.Godot) return;

  var EVENT = 'webui_edit';
  var UI_ID = 'webui-edit-ui';
  var BLOCKED = ['pointerdown', 'pointerup', 'pointercancel', 'mousedown', 'mouseup', 'touchstart', 'touchend', 'touchmove', 'click', 'dblclick', 'contextmenu'];
  var SHOWN_ATTRS = ['src', 'href', 'alt', 'title', 'placeholder', 'value', 'type', 'name', 'for', 'role', 'aria-label', 'target'];
  var TEXT_TAGS = /^(p|span|h[1-6]|label|small|b|i|em|strong|li|dt|dd|legend|figcaption|code|pre|blockquote|output|td|th|summary|time|mark|sub|sup|u|s|a|dfn|abbr|cite|q|kbd|samp|var)$/;
  var SVG_TAGS = /^(svg|path|circle|rect|ellipse|line|polyline|polygon|g|use|symbol|text|tspan)$/;
  var INPUT_TAGS = /^(input|textarea|select|option|output|progress|meter)$/;
  var DEFAULT_PROPS = ['color', 'font-size', 'font-weight', 'background-color', 'width', 'height', 'margin-top', 'padding-top', 'border-radius', 'display', 'opacity'];

  var enabled = true;
  var selected = null;
  var config = {};       // key -> {read, write, detect, inherited}
  var hoverBox, selectBox, root;

  function propConfig(key) {
    var c = config[key] || {};
    return { read: c.read || key, write: c.write || key, detect: c.detect || [c.read || key], inherited: !!c.inherited };
  }
  DEFAULT_PROPS.forEach(function (k) { config[k] = {}; });

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

  // The element to select at a point. The browser's own hit test skips elements with `pointer-events: none`
  // (the HUD readouts of this project's demo are such elements), so those are considered too: when one of
  // them is smaller than what the browser found, it is what the user is pointing at. Full-screen overlays
  // never win, being larger than anything under them.
  function pickAt(x, y, hit) {
    function area(el) { var r = el.getBoundingClientRect(); return r.width * r.height; }
    var best = hit || null;
    var bestArea = hit ? area(hit) : Infinity;
    var all = document.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (isOurs(el) || /^(html|head|body|script|style|meta|link|title)$/i.test(el.tagName)) continue;
      var r = el.getBoundingClientRect();
      var a = r.width * r.height;
      if (a <= 0 || x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
      if (a > bestArea || (a === bestArea && best === hit)) continue;
      var cs = getComputedStyle(el);
      if (cs.pointerEvents !== 'none' || cs.visibility === 'hidden') continue;
      best = el;
      bestArea = a;
    }
    return best;
  }

  function targetOf(e) {
    // Synthetic events (tests) carry no real position: use their target.
    return e.isTrusted ? pickAt(e.clientX, e.clientY, e.target) : e.target;
  }

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

  // Approximate specificity of one complex selector (a*10000 + b*100 + c); the browser stays the authority,
  // and every change is verified against it (see apply).
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

  function normalize(sel) { return (sel || '').replace(/["']/g, '').replace(/\s+/g, '').toLowerCase(); }

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

  function findSheet(file) {
    var found = null;
    Array.prototype.forEach.call(document.styleSheets, function (sheet) {
      if (!found && sheet.href && relativeHref(sheet) === file) found = sheet;
    });
    return found;
  }

  function findRule(file, path) {
    var sheet = findSheet(file);
    if (!sheet) return null;
    var rules = sheet.cssRules, rule = null;
    for (var i = 0; i < path.length; i++) {
      rule = rules[path[i]];
      if (!rule) return null;
      rules = rule.cssRules;
    }
    return rule && rule.type === CSSRule.STYLE_RULE ? rule : null;
  }

  function watchedNames() {
    var names = {};
    Object.keys(config).forEach(function (k) {
      var c = propConfig(k);
      names[c.read] = 1; names[c.write] = 1;
      c.detect.forEach(function (d) { names[d] = 1; });
    });
    return names;
  }

  // Rules matching `el` with where they live. `declared` has the watched longhands each rule sets (the
  // browser expands shorthands), which is what tells the editor that a rule outside the files (a
  // <style> block) also sets a property.
  function matchedRules(el, withAffects) {
    var watch = watchedNames();
    var rules = [];
    eachStyleRule(function (rule, sheet, path, conditions, order) {
      var spec = matchingSpecificity(rule, el);
      if (spec < 0) return;
      var declared = {};
      for (var i = 0; i < rule.style.length; i++) {
        var name = rule.style[i];
        if (watch[name]) declared[name] = rule.style.getPropertyPriority(name) === 'important';
      }
      var affects = -1;
      if (withAffects) {
        try { affects = document.querySelectorAll(rule.selectorText).length; } catch (e) { /* selector with states */ }
      }
      var vars = (rule.style.cssText.match(/var\(\s*--[\w-]+/g) || []).map(function (v) { return v.replace(/var\(\s*/, ''); });
      rules.push({
        file: relativeHref(sheet), inline: !sheet.href, path: path, selector: rule.selectorText,
        conditions: conditions, specificity: spec, order: order, affects: affects, declared: declared, vars: vars,
      });
    });
    return rules;
  }

  // ---------------------------------------------------------------- what an element is

  function ownText(el) {
    var nodes = Array.prototype.filter.call(el.childNodes, function (n) { return n.nodeType === 3 && n.nodeValue.trim() !== ''; });
    return nodes.length ? nodes.map(function (n) { return n.nodeValue; }).join('').trim() : '';
  }

  function textNodesOf(el) {
    return Array.prototype.filter.call(el.childNodes, function (n) { return n.nodeType === 3 && n.nodeValue.trim() !== ''; });
  }

  // An element's own text is editable when it is exactly one piece of text (other elements may sit next to
  // it, as in <button><svg/>Play</button>); `unique` says no other element has the same single text.
  function textInfo(el) {
    var textNodes = textNodesOf(el);
    var editable = textNodes.length === 1 && !INPUT_TAGS.test(el.tagName.toLowerCase());
    var text = ownText(el);
    var count = 0;
    if (editable) {
      Array.prototype.forEach.call(document.querySelectorAll(el.tagName.toLowerCase()), function (other) {
        if (textNodesOf(other).length === 1 && ownText(other) === text) count++;
      });
    }
    return { text: text.slice(0, 200), editable: editable, unique: editable && count === 1, mixed: textNodes.length > 1 };
  }

  // Elements inside `el` that hold one piece of text each (the <b>Play</b> inside a button).
  function innerTexts(el) {
    var out = [];
    var all = el.querySelectorAll('*');
    for (var i = 0; i < all.length && out.length < 8; i++) {
      var d = all[i];
      if (isOurs(d) || /^(script|style)$/i.test(d.tagName)) continue;
      var info = textInfo(d);
      if (info.editable) out.push({ selector: cssPath(d), tag: d.tagName.toLowerCase(), text: info.text, unique: info.unique });
    }
    return out;
  }

  function classify(el, display) {
    var tag = el.tagName.toLowerCase();
    if (tag === 'img' || tag === 'picture') return 'image';
    if (tag === 'video' || tag === 'audio' || tag === 'canvas' || tag === 'iframe' || tag === 'object' || tag === 'embed') return 'media';
    if (SVG_TAGS.test(tag) || el instanceof SVGElement) return 'svg';
    if (tag === 'button' || el.getAttribute('role') === 'button' || (tag === 'input' && /^(button|submit|reset|checkbox|radio)$/.test(el.type))) return 'button';
    if (tag === 'a') return 'link';
    if (INPUT_TAGS.test(tag)) return 'input';
    var hasText = ownText(el) !== '';
    if (el.children.length === 0 && (hasText || TEXT_TAGS.test(tag))) return 'text';
    if (TEXT_TAGS.test(tag) && !/flex|grid/.test(display)) return 'text';
    return 'container';
  }

  function shownAttributes(el) {
    var out = {};
    SHOWN_ATTRS.forEach(function (name) {
      if (el.hasAttribute(name)) out[name] = (el.getAttribute(name) || '').slice(0, 300);
    });
    return out;
  }

  function fontFamilies() {
    var out = [];
    try { document.fonts.forEach(function (f) { if (out.indexOf(f.family) < 0) out.push(f.family.replace(/^"|"$/g, '')); }); } catch (e) { /* no FontFaceSet */ }
    return out;
  }

  function sheetsInfo() {
    var out = [];
    Array.prototype.forEach.call(document.styleSheets, function (sheet) {
      var file = relativeHref(sheet);
      if (!file || (sheet.ownerNode && isOurs(sheet.ownerNode))) return;
      var count = 0;
      try { count = sheet.cssRules.length; } catch (e) { return; }
      out.push({ file: file, rules: count });
    });
    return out;
  }

  // ---------------------------------------------------------------- reporting

  function selection(el) {
    var cs = getComputedStyle(el);
    var display = cs.display;
    var computed = {};
    var inherited = {};
    var matched = matchedRules(el, true);
    Object.keys(config).forEach(function (key) {
      var c = propConfig(key);
      computed[key] = cs.getPropertyValue(c.read);
    });

    var inline = {};
    for (var i = 0; i < el.style.length; i++) {
      var iname = el.style[i];
      inline[iname] = { value: el.style.getPropertyValue(iname), important: el.style.getPropertyPriority(iname) === 'important' };
    }

    Object.keys(config).forEach(function (key) {
      var c = propConfig(key);
      if (!c.inherited) return;
      var own = matched.some(function (r) { return c.detect.some(function (d) { return d in r.declared; }); }) || c.detect.some(function (d) { return d in inline; });
      if (own) return;
      for (var anc = el.parentElement; anc; anc = anc.parentElement) {
        var rules = matchedRules(anc, false).filter(function (r) { return c.detect.some(function (d) { return d in r.declared; }); });
        var inl = c.detect.some(function (d) { return anc.style.getPropertyValue(d) !== ''; });
        if (rules.length || inl) {
          rules.sort(function (a, b) { return a.specificity - b.specificity || a.order - b.order; });
          var top = rules[rules.length - 1];
          inherited[key] = { from: cssPath(anc), tag: anc.tagName.toLowerCase(), selector: top ? top.selector : 'style attribute', file: top ? top.file : '' };
          break;
        }
      }
    });

    var varNames = {};
    matched.forEach(function (r) { r.vars.forEach(function (v) { varNames[v] = 1; }); });
    var vars = {};
    Object.keys(varNames).forEach(function (v) { vars[v] = cs.getPropertyValue(v).trim(); });

    var info = textInfo(el);
    var r = el.getBoundingClientRect();
    var parent = el.parentElement;
    return {
      op: 'selected', selector: cssPath(el), tag: el.tagName.toLowerCase(), id: el.id || '',
      id_unique: !!el.id && document.querySelectorAll('#' + CSS.escape(el.id)).length === 1,
      classes: Array.prototype.slice.call(el.classList), kind: classify(el, display),
      attrs: shownAttributes(el), text: info.text, text_editable: info.editable, text_unique: info.unique, text_mixed: info.mixed,
      texts: innerTexts(el),
      display: display, position: cs.position, parent_display: parent ? getComputedStyle(parent).display : '',
      animated: cs.animationName !== 'none', children: el.children.length,
      rect: { x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) },
      computed: computed, inline: inline, inherited: inherited, vars: vars, rules: matched,
      fonts: fontFamilies(), sheets: sheetsInfo(),
    };
  }

  function emit(payload) { window.Godot.emit(EVENT, payload); }

  function select(el) {
    selected = el;
    if (!el) { emit({ op: 'cleared' }); return; }
    emit(selection(el));
  }

  // ---------------------------------------------------------------- applying and verifying

  // What `read` would compute to on `el` if `write: value` were set with top priority.
  function expectedValue(el, write, read, value) {
    var prevT = el.style.getPropertyValue('transition'), prevTP = el.style.getPropertyPriority('transition');
    var prevV = el.style.getPropertyValue(write), prevVP = el.style.getPropertyPriority(write);
    el.style.setProperty('transition', 'none', 'important');
    el.style.setProperty(write, value, 'important');
    var expected = getComputedStyle(el).getPropertyValue(read);
    if (prevV) el.style.setProperty(write, prevV, prevVP); else el.style.removeProperty(write);
    if (prevT) el.style.setProperty('transition', prevT, prevTP); else el.style.removeProperty('transition');
    return expected;
  }

  function currentValue(el, read) {
    var prevT = el.style.getPropertyValue('transition'), prevTP = el.style.getPropertyPriority('transition');
    el.style.setProperty('transition', 'none', 'important');
    var v = getComputedStyle(el).getPropertyValue(read);
    if (prevT) el.style.setProperty('transition', prevT, prevTP); else el.style.removeProperty('transition');
    return v;
  }

  // What stands in the way when a declaration has no effect.
  function blockerFor(el, c, target) {
    if (c.detect.some(function (d) { return el.style.getPropertyValue(d) !== ''; })) return 'the element\'s inline style attribute';
    var best = null;
    matchedRules(el, false).forEach(function (r) {
      if (target && r.file === target.file && r.path.join('.') === target.path.join('.')) return;
      if (!c.detect.some(function (d) { return d in r.declared; })) return;
      var rank = (c.detect.some(function (d) { return r.declared[d]; }) ? 1e9 : 0) + r.specificity * 1000 + r.order;
      if (!best || rank > best.rank) best = { rank: rank, text: (r.file || 'a <style> block') + '  ' + r.selector };
    });
    if (best) return best.text;
    return el.style.animationName !== 'none' && getComputedStyle(el).animationName !== 'none' ? 'an animation' : 'something outside the stylesheets (an animation or the browser)';
  }

  function checkEffect(el, c, value) {
    var expected = expectedValue(el, c.write, c.read, value);
    var actual = currentValue(el, c.read);
    return { ok: expected === actual, expected: expected, actual: actual };
  }

  function apply(msg) {
    var c = propConfig(msg.prop);
    var result = { op: 'apply_result', ok: false, file: msg.file, path: msg.path, prop: msg.prop, value: msg.value };
    var rule = findRule(msg.file, msg.path || []);
    if (!rule) { result.error = 'rule_not_found'; return emit(result); }
    if (normalize(rule.selectorText) !== normalize(msg.selector)) { result.error = 'selector_mismatch'; return emit(result); }
    var priority = rule.style.getPropertyPriority(c.write);
    var before = rule.style.getPropertyValue(c.write);
    if (msg.value === '') {
      rule.style.removeProperty(c.write);
    } else {
      if (!CSS.supports(c.write, msg.value)) { result.error = 'invalid_value'; return emit(result); }
      rule.style.setProperty(c.write, msg.value, msg.important ? 'important' : priority);
      if (selected && msg.verify !== false) {
        var effect = checkEffect(selected, c, msg.value);
        if (!effect.ok) {
          if (before) rule.style.setProperty(c.write, before, priority); else rule.style.removeProperty(c.write);
          result.error = 'ineffective';
          result.expected = effect.expected;
          result.actual = effect.actual;
          result.blocker = blockerFor(selected, c, { file: msg.file, path: msg.path || [] });
          return emit(result);
        }
      }
    }
    result.ok = true;
    emit(result);
    if (selected) emit(selection(selected));
  }

  function addRule(msg) {
    var result = { op: 'rule_result', kind: 'add', ok: false, file: msg.file, selector: msg.selector };
    var sheet = findSheet(msg.file);
    if (!sheet) { result.error = 'sheet_not_found'; return emit(result); }
    var index = sheet.cssRules.length;
    try { sheet.insertRule(msg.selector + '{}', index); } catch (e) { result.error = 'bad_selector'; return emit(result); }
    var rule = sheet.cssRules[index];
    var props = Object.keys(msg.decls || {});
    for (var i = 0; i < props.length; i++) {
      var c = propConfig(props[i]);
      var value = msg.decls[props[i]];
      if (!CSS.supports(c.write, value)) { sheet.deleteRule(index); result.error = 'invalid_value'; result.prop = props[i]; return emit(result); }
      rule.style.setProperty(c.write, value, msg.important ? 'important' : '');
    }
    if (selected) {
      for (var j = 0; j < props.length; j++) {
        var effect = checkEffect(selected, propConfig(props[j]), msg.decls[props[j]]);
        if (!effect.ok) {
          sheet.deleteRule(index);
          result.error = 'ineffective'; result.prop = props[j]; result.expected = effect.expected; result.actual = effect.actual;
          result.blocker = blockerFor(selected, propConfig(props[j]), null);
          return emit(result);
        }
      }
    }
    result.ok = true; result.path = [index];
    emit(result);
    if (selected) emit(selection(selected));
  }

  function removeRule(msg) {
    var result = { op: 'rule_result', kind: 'remove', ok: false, file: msg.file, path: msg.path };
    var rule = findRule(msg.file, msg.path || []);
    var sheet = findSheet(msg.file);
    if (!rule || !sheet || (msg.path || []).length !== 1 || normalize(rule.selectorText) !== normalize(msg.selector)) { result.error = 'rule_not_found'; return emit(result); }
    sheet.deleteRule(msg.path[0]);
    result.ok = true;
    emit(result);
    if (selected) emit(selection(selected));
  }

  function applyText(msg) {
    var result = { op: 'content_result', kind: 'text', ok: false };
    var el = selected;
    if (msg.selector) {  // text of an element inside the selected one
      try { el = document.querySelector(msg.selector); } catch (e) { el = null; }
    }
    var info = el && textInfo(el);
    if (!info || !info.editable) { result.error = 'not_editable'; return emit(result); }
    var node = textNodesOf(el)[0];
    var lead = node.nodeValue.match(/^\s*/)[0], trail = node.nodeValue.match(/\s*$/)[0];
    node.nodeValue = lead + String(msg.text) + trail;
    result.ok = true;
    emit(result);
    emit(selection(selected || el));
  }

  function applyAttr(msg) {
    var result = { op: 'content_result', kind: 'attr', name: msg.name, ok: false };
    if (!selected || !/^[a-zA-Z][\w:-]*$/.test(msg.name || '')) { result.error = 'not_editable'; return emit(result); }
    if (msg.value === null || msg.value === undefined) selected.removeAttribute(msg.name);
    else selected.setAttribute(msg.name, String(msg.value));
    result.ok = true;
    emit(result);
    emit(selection(selected));
  }

  // ---------------------------------------------------------------- wiring

  function start() {
    buildOverlay();
    BLOCKED.forEach(function (name) {
      document.addEventListener(name, function (e) {
        if (!enabled || isOurs(e.target)) return;
        e.stopImmediatePropagation();
        if (e.cancelable) e.preventDefault();
        if (name === 'click') select(targetOf(e));
      }, true);
    });
    var hoverFrame = 0;
    document.addEventListener('pointermove', function (e) {
      if (!enabled || isOurs(e.target) || hoverFrame) return;
      hoverFrame = requestAnimationFrame(function () {
        hoverFrame = 0;
        place(hoverBox, targetOf(e));
      });
    }, true);
    document.addEventListener('pointerleave', function () { hoverBox.style.display = 'none'; }, true);

    window.Godot.onEvent(EVENT, function (msg) {
      if (!msg || typeof msg !== 'object') return;
      switch (msg.op) {
        case 'config':
          if (msg.props && typeof msg.props === 'object') {
            config = msg.props;
            if (selected) emit(selection(selected));
          }
          break;
        case 'enable':
          enabled = !!msg.on;
          if (!enabled) hoverBox.style.display = 'none';
          break;
        case 'select':
          var el = null;
          if (typeof msg.x === 'number' && typeof msg.y === 'number') {  // as a click at that point would
            el = pickAt(msg.x, msg.y, document.elementFromPoint(msg.x, msg.y));
          } else {
            try { el = document.querySelector(msg.selector); } catch (e) { /* invalid selector */ }
          }
          select(el);
          break;
        case 'apply': apply(msg); break;
        case 'add_rule': addRule(msg); break;
        case 'remove_rule': removeRule(msg); break;
        case 'apply_text': applyText(msg); break;
        case 'apply_attr': applyAttr(msg); break;
      }
    });
    requestAnimationFrame(tick);
    emit({ op: 'ready' });
  }

  window.__webuiEdit = { select: select, selection: selection, enable: function (on) { enabled = !!on; }, classify: classify, pickAt: pickAt };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
