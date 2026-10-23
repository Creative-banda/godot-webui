---
name: godot-webui
description: Build and modify HTML/CSS/JavaScript game interfaces (HUDs, menus, overlays) for Godot 4.7 projects that use the Godot WebUI addon (GodotWebUI class, Godot.emit / Godot.onState / Godot.onEvent, an Android WebView overlay). Use when a task involves the webui addon, a res://ui folder of HTML, setting up WebUI in a project, previewing a WebUI interface on desktop, or exporting it to Android. Do not use for plain Godot Control-node UI.
---

# Godot WebUI

Godot WebUI shows an HTML page as a transparent screen-space WebView above the running game (Android) and connects it to GDScript with a small JSON bridge. **Godot owns gameplay and game state; the page renders and sends intent.**

This skill is a map, not the source of truth. **The addon source in the project is authoritative.** When anything is unclear, read it instead of guessing:

- `addons/webui/plugin.cfg` (version), `addons/webui/webui.gd` (GDScript API, doc comments), `addons/webui/web/godot.js` (page API, header comment), `addons/webui/webui_bridge.gd` (message validation), `addons/webui/export_plugin.gd` and `webui_export_scan.gd` (packaging).
- The addon's `README.md` and `docs/` if present. In a project that only copied `addons/webui`, the source files above are all you have.

Never invent methods from their names (there is no `Godot.send`, `Godot.call`, `GodotWebUI.call_js`, `WebUI.new()`), never copy an example without checking that every call exists in the installed version, and never assume a browser feature works inside the Android WebView (see `references/touch-and-runtime.md`).

## 1. Decide whether WebUI fits

Use WebUI for styled, animated, text-heavy or responsive 2D interfaces: HUDs, menus, settings, inventories, dialogs, shops, pause screens, onboarding.

Prefer native Godot `Control` nodes for: UI in the game world or on 3D objects, anything that must be drawn *over* the overlay or composited with the game's shaders (the overlay is always on top of the game surface), text input / on-screen keyboard (not implemented or verified), gamepad or focus navigation (not implemented), per-frame data at high rates, debug tools, and any project that must ship on iOS or desktop (not supported runtimes). A project can mix both. Do not replace working native UI unless the user asks.

## 2. Inspect the project first

1. Is the addon installed and enabled? Look for `addons/webui/` and `res://addons/webui/plugin.cfg` in `[editor_plugins] enabled=` of `project.godot`. If not, see "Setup" below; do not hand-write the plugin entry if you can run the script.
2. Find existing UI: folders containing `.html` outside `addons/`, scripts that create `GodotWebUI.new()` or call `.start(`, `webui/export/ui_folders` in `project.godot`. Follow the project's existing structure and naming.
3. Read the installed API (files above) before writing code. Note the addon version and Godot version (target 4.7.1).

## 3. Build the UI

Files and packaging (details: `references/ui-authoring.md`):

- Put pages in one folder (for example `res://ui/`) containing an `index.html` (or the page name you pass to `start`). The export plugin packages every folder outside `addons/` that contains an `.html` file, with its whole subtree, as raw files, and always packages `godot.js`. Override with the project setting `webui/export/ui_folders`. A folder containing a `.gdignore` is never auto-packaged. Do not add an export filter for these files.
- Use **relative URLs** only. Bundle CSS, JS, images and fonts in the folder. Remote URLs (CDNs, web fonts, analytics, `fetch` to other hosts) are blocked.
- `window.Godot` is injected before page scripts. Do not add a `<script src>` for it.
- Page basics: `<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, viewport-fit=cover">`, `html, body { background: transparent; margin: 0; overflow: hidden; touch-action: none; user-select: none; }`.
- Lay out with `%`, `vw`/`vh`, `clamp()`, flex/grid and `env(safe-area-inset-*)`. Do not hardcode pixel coordinates for a single phone. Test landscape and portrait if the game supports both.
- Keep gameplay out of JavaScript: no damage math, cooldown authority, inventory truth or save data in the page.

## 4. Connect it to Godot

Full API with arguments, limits and error codes: `references/api.md`. Worked examples: `references/patterns.md`.

Page to Godot (always intent, always a plain object payload):

```js
Godot.emit('attack', { heavy: false });          // name /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/, payload < 64 KB
```
```gdscript
ui.on("attack", func(payload: Dictionary) -> void:   # validate types yourself
    if typeof(payload.get("heavy", false)) == TYPE_BOOL:
        player.attack(payload.get("heavy", false)))
```

Godot to page: two different channels.

| | Godot | Page | Use for |
|---|---|---|---|
| State | `ui.set_state("hud", {...})` | `Godot.onState("hud", fn)` | values the page must always show: health, settings, inventory. Newest wins; late subscribers get the latest value |
| Event | `ui.emit_event("hit", {...})` | `Godot.onEvent("hit", fn)` | something happened once: toast, hit flash. Ordered, never replayed |

Rules that prevent the usual bugs:

- Create `GodotWebUI.new()`, `add_child()` it, register `on()` handlers and `page_ready`, then `start(ui_dir)`. `start()` returns `false` and emits `error` on failure. Only one overlay can run at a time.
- **Resend full state from `page_ready`** (fires on first load, every `load_page`, hot reload and recovery). Do not assume the page remembers anything across loads.
- `send()` and `Godot.on` still exist as aliases of `set_state` / `onState`; write new code with the explicit names.
- Validate every incoming payload in GDScript. Never expose a "call any method" event.
- Handle `error(code, text)`; see `references/troubleshooting.md` for what each code means.
- Held controls (joysticks, hold buttons): Pointer Events with `setPointerCapture`, release on `pointerup`, `pointercancel` and `lostpointercapture`, and register the release with `Godot.guard(fn)` so blur, page hide and app pause cannot leave input stuck. `examples/playable_character/ui/hud.js` shows the pattern.

## 5. Touch, Android and desktop (summary)

- Touch mode defaults to `AUTO`: the overlay takes every touch until the page calls `Godot.touchRegions()`; then only elements marked `data-webui-touch` take touches and the rest reaches the game. Use `MODAL` for full-screen menus. Details and limits: `references/touch-and-runtime.md`.
- Android is the only supported runtime. The desktop preview (editor only, F5/F6) is a development aid: mouse and keyboard only, no touch pass-through, different web engine, different security. Never treat "works in the preview" as "works on the device".
- In the Android WebView, `localStorage`/DOM storage is disabled, `eval`/`new Function` are blocked by the CSP, popups and external navigation are blocked, zoom is off, and the page cannot blur the game behind it (`backdrop-filter`). Keep persistence in Godot.
- Recovery after a WebView renderer crash is best effort and untested on a device. Pause/resume, orientation changes and pass-through with a game that reads touches are not verified on a device.

## 6. Setup and preview (what to tell the user)

- In the addon repository: `python tools/setup.py` installs the pinned desktop-preview dependency outside the project and checks the Android toolchain; `python tools/setup.py add-to-project PATH --enable-plugin --with-skill` installs the addon (and this skill) into a game project. Details: `docs/setup.md` in the repository.
- Preview: run the project or scene from the Godot editor (F5/F6). Edited UI files hot-reload. It needs the one-time `python tools/setup.py wry` step.
- Android: enable the plugin, install the Android build template, turn on Use Gradle Build, export. No export filter is needed for the UI.

## 7. Finish by reporting

Tell the user: which files you created or changed; how to preview (scene to run, setup step if missing); which events and states the bridge now carries (names and payload shapes); any behavior you could not verify (anything touching a real device); and relevant limitations from section 5. Do not claim a device behavior works unless it was run on a device.

## Reference files

- `references/api.md`: GDScript and JavaScript API, limits, signals, error codes.
- `references/ui-authoring.md`: folder layout, packaging rules, layout, assets, accessibility notes.
- `references/patterns.md`: tested-shape examples: button to action, state to UI, events, pages and navigation, held input, validation.
- `references/touch-and-runtime.md`: touch modes, Android vs desktop preview, lifecycle, verified vs unverified.
- `references/troubleshooting.md`: error codes and symptoms.
