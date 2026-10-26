/*
 * Godot WebUI - world-space page, desktop preview helper (development only).
 *
 * Injected after godot.js and capture.js into the hidden preview copy of a page that is shown on a 3D surface
 * (webui_surface_preview.gd). Never part of the original HTML, an Android export or the game.
 *
 * It lets Godot "tap" the page: a raycast on the 3D screen becomes a page pixel, and this script sends the page the
 * events a finger would (pointerdown, mousedown, pointerup, mouseup, click) at that point. These are synthetic events
 * (isTrusted is false); CSS :hover and :active are NOT reproduced, and nothing is focused or scrolled. On Android the
 * same tap is a real touch.
 */
(function () {
  'use strict';
  if (window.__webuiSurfaceTap) return;

  function fire(target, type, x, y, buttons) {
    var common = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, screenX: x, screenY: y, button: 0, buttons: buttons };
    if (type.indexOf('pointer') === 0 && window.PointerEvent) {
      target.dispatchEvent(new PointerEvent(type, Object.assign({ pointerId: 1, pointerType: 'touch', isPrimary: true, width: 1, height: 1 }, common)));
    } else {
      target.dispatchEvent(new MouseEvent(type, common));
    }
  }

  window.__webuiSurfaceTap = function (x, y) {
    var target = document.elementFromPoint(x, y);
    if (!target) return false;
    fire(target, 'pointerover', x, y, 0);
    fire(target, 'pointerdown', x, y, 1);
    fire(target, 'mousedown', x, y, 1);
    fire(target, 'pointerup', x, y, 0);
    fire(target, 'mouseup', x, y, 0);
    fire(target, 'click', x, y, 0);
    return true;
  };
})();
