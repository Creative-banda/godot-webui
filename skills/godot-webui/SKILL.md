---
name: godot-webui
description: Build and modify HTML/CSS/JavaScript game interfaces (HUDs, menus, overlays) for Godot 4.7 projects that use the Godot WebUI addon (GodotWebUI class, Godot.emit / Godot.onState / Godot.onEvent, an Android WebView overlay, the WebUI visual editor dock). Use when a task involves the webui addon, a res://ui folder of HTML, installing or setting up WebUI in a project, writing a new screen or HUD page, making a page editable in the visual editor, previewing a WebUI interface on desktop, or exporting it to Android. Do not use for plain Godot Control-node UI.
---

# Godot WebUI

Godot WebUI shows an HTML page as a transparent screen-space WebView above the running game (Android) and connects it to GDScript with a small JSON bridge. **Godot owns gameplay and game state; the page renders and sends intent.**

Read this whole file before doing any WebUI work. The rules below are binding. The addon source in the project is authoritative; this skill is a map to it, not a replacement:

- `addons/webui/plugin.cfg` (version), `addons/webui/webui.gd` (GDScript API, doc comments), `addons/webui/web/godot.js` (page API, header comment), `addons/webui/webui_bridge.gd` (message validation), `addons/webui/export_plugin.gd` and `webui_export_scan.gd` (packaging).
- The addon's `README.md` and `docs/` if present. In a project that only copied `addons/webui`, the source files above are all you have.

## Rules you must follow (no exceptions without the user's say-so)

1. **Never invent API.** The complete public surface is in `references/api.md` and the source files above. There is no `Godot.send`, `Godot.call`, `Godot.fetch`, `GodotWebUI.call_js`, `GodotWebUI.eval`, `WebUI.new()` (the class is `GodotWebUI`), `ui.send_event`, or generic "call method X" bridge. If you are not sure a call exists, grep the installed source before writing it.
2. **No gameplay in the page.** No damage math, cooldowns, inventory, saves, scoring or rules in JavaScript. The page sends intent (`Godot.emit("attack", {heavy: false})`) and renders what Godot sends. Validate every payload in GDScript.
3. **Android is the only supported runtime.** Do not add iOS, desktop-runtime or browser-hosted code, remote URLs, CDNs, web fonts, analytics, `fetch` to other hosts, `eval`/`new Function`, `localStorage`, popups or external navigation. The desktop preview is an editor-only development aid, never a target.
4. **Relative URLs only; one UI folder** (outside `addons/`) with an `.html` file in it. `window.Godot` is injected: never add a script tag for it.
5. **Do not claim anything about a real device** (touch pass-through, multi-touch, pause/resume, orientation, performance) unless it was run on one. Say what you could not verify.
6. **Keep the existing structure and naming of the project.** Do not rewrite working native UI or whole files for a small change; edit in place.
7. **Write pages so the visual editor can edit them** (section 4). This is how the user adjusts the design without you.
8. **Make every page responsive and resolution-independent; never design for one screen.** Applies to every screen you create or modify. The addon already normalises big screens like Godot's own stretch (`GodotWebUI.ui_reference_size`, default 720): above that short side the page is scaled up so your CSS sees about a 720-px-high layout space (a 1080p/1440p/4K screen = about 1280 x 720); phones are untouched. So author in ordinary CSS px for 360 x 640 up to about 1280 x 720 (text 14-24 px, touch targets at least 44 px), use extra width and height for layout (columns, margins, capped centered content), not bigger controls, and never scale the page yourself (no root `zoom`/`transform: scale`, no `devicePixelRatio` layout maths, no `vw` type; canvases use `Godot.pixelRatio`). Fluid sizing (`clamp()`, `vmin`, flex/grid), `@media` breakpoints, safe-area insets on edge-anchored elements. Check the page at a phone, a tablet and a large size and report which, saying none was a real device. Details: `references/ui-authoring.md` (Resolution independence) and `references/responsive.md`.
9. **Never use editor-only classes in game code**: `WebUIScreenInspector`, `WebUIScreenPreview`, `WebUIEditPreview`, `WebUIEditLink`, `WebUIEditorDock`, `WebUIEditorModel`, `WebUICssPatcher`, `WebUIHtmlPatcher`, `WebUICssCatalog`, `web/edit_mode.js`, and the `.webui-edit/` folder exist only for the editor.
10. **Animate `transform` and `opacity` only; never animate `box-shadow`, `filter: blur/drop-shadow`, layout properties or big gradients.** On a mid-range phone those repaint every frame and drop the page to 10-40 FPS while it is smooth on a PC (measured, no addon setting fixes it). Keep canvas effects small, pause hidden animations, and measure on a device before calling a page smooth. Details and numbers: `references/animation-performance.md`.

## 1. Decide whether WebUI fits

Use WebUI for styled, animated, text-heavy or responsive 2D interfaces: HUDs, menus, settings, inventories, dialogs, shops, pause screens, onboarding.

Prefer native Godot `Control` nodes for: UI in the game world or on 3D objects, anything that must be drawn *over* the overlay or composited with the game's shaders (the overlay is always on top of the game surface), text input / on-screen keyboard (not implemented or verified), gamepad or focus navigation (not implemented), per-frame data at high rates, debug tools, and any project that must ship on iOS or desktop (not supported runtimes). A project can mix both. Do not replace working native UI unless the user asks.

## 2. Inspect the project first

1. Is the addon installed and enabled? Look for `addons/webui/` and `res://addons/webui/plugin.cfg` in `[editor_plugins] enabled=` of `project.godot`. If not, follow `references/new-project.md` (install with the setup script; do not hand-write the plugin entry).
2. Find existing UI: folders containing `.html` outside `addons/`, scripts that create `GodotWebUI.new()` or call `.start(`, `webui/export/ui_folders` in `project.godot`. Follow the project's existing structure and naming.
3. Read the installed API (files above). Note the addon version and Godot version (target 4.7.1).

## 3. Build the UI

Files and packaging (details: `references/ui-authoring.md`):

- Put pages in one folder (for example `res://ui/`) containing an `index.html` (or the page name you pass to `start`). The export plugin packages every folder outside `addons/` that contains an `.html` file, with its whole subtree, as raw files, and always packages `godot.js`. Override with the project setting `webui/export/ui_folders`. A folder containing a `.gdignore`, and any folder whose name starts with `.`, is never packaged. Do not add an export filter for these files.
- Page basics: `<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, viewport-fit=cover">`, `html, body { background: transparent; margin: 0; overflow: hidden; touch-action: none; user-select: none; }`.
- Lay out responsively (rule 8): `%`, `vw`/`vh`/`vmin`, `clamp()`, flex/grid and `env(safe-area-inset-*)`, plus `@media` breakpoints. Do not hardcode pixel coordinates for a single phone or assume one resolution. Keep controls at ordinary CSS-pixel sizes for the scaled layout space (no viewport-unit type, no self-scaling), cap and center content, and test landscape, portrait, a tablet size and a large window.

### Connect it to Godot

Full API with arguments, limits and error codes: `references/api.md`. Worked examples: `references/patterns.md`.

```js
Godot.emit('attack', { heavy: false });          // name /^[A-Za-z][A-Za-z0-9_.:-]{0,63}$/, plain-object payload < 64 KB
```
```gdscript
ui.on("attack", func(payload: Dictionary) -> void:   # validate types yourself
    if typeof(payload.get("heavy", false)) == TYPE_BOOL:
        player.attack(payload.get("heavy", false)))
```

| | Godot | Page | Use for |
|---|---|---|---|
| State | `ui.set_state("hud", {...})` | `Godot.onState("hud", fn)` | values the page must always show: health, settings, inventory. Newest wins; late subscribers get the latest value |
| Event | `ui.emit_event("hit", {...})` | `Godot.onEvent("hit", fn)` | something happened once: toast, hit flash. Ordered, never replayed |

- Create `GodotWebUI.new()`, `add_child()` it, register `on()` handlers and `page_ready`, then `start(ui_dir)`. `start()` returns `false` and emits `error` on failure. Only one overlay can run at a time.
- **Resend full state from `page_ready`** (fires on first load, every `load_page`, hot reload and recovery). The page remembers nothing across loads.
- `send()` and `Godot.on` still exist as aliases of `set_state` / `onState`; write new code with the explicit names.
- Handle `error(code, text)`; see `references/troubleshooting.md`.
- Held controls (joysticks, hold buttons): Pointer Events with `setPointerCapture`, release on `pointerup`, `pointercancel` and `lostpointercapture`, and register the release with `Godot.guard(fn)`. `examples/playable_character/ui/hud.js` shows the pattern.

## 4. Write pages the visual editor can edit

The addon ships a visual editor (the **WebUI** dock in the Godot editor): the user opens a page in a preview, clicks an element, and changes its CSS, text and attributes; Save patches the source files in place. It can only change what it can find safely, so write pages like this. These rules are what makes the difference between "the user can tweak it" and "the user has to ask an AI for every change":

1. **CSS goes in external `.css` files** linked with `<link rel="stylesheet" href="style.css">`. Do not use `<style>` blocks and do not use `style="..."` attributes: the editor cannot edit them (it shows them read-only). Setting styles from JavaScript at run time (`el.style.x = ...`) is only for values that really depend on state (a bar's width); keep everything else in CSS.
2. **Plain, flat CSS.** Ordinary rules, `@media` and `@keyframes`. No CSS nesting (`&`) and no `@container`; link stylesheets with `<link>` rather than `@import`. Keep values free of `;`, `{`, `}` and backslashes; put images and fonts in files and reference them with `url(file.png)` instead of `data:` URLs.
3. **Class-based rules; unique `id` on elements the user will want to tweak individually** (buttons, labels, panels, images). An `id` lets the editor write an element-only rule instead of changing a class shared by many elements, and is required for editing `alt`/`title`/`placeholder`/`value`.
4. **Theme with CSS custom properties** in `:root` (`--accent: #3ee6a0;`) and use them with `var(--accent)`. Design tokens in one place stay consistent.
5. **Static text goes in the HTML**, exactly once per element (`<button id="start">Start</button>`). Text that JavaScript builds (templates, `textContent = ...`) cannot be edited in the file; only use script-filled text for values that come from Godot state, and give those elements a readable placeholder.
6. **Plain HTML/CSS/JS, no framework that generates the DOM** (React, Vue, Svelte, Tailwind runtime). The editor reads the live DOM but saves to the source files, which a generated DOM does not map to.
7. **List the state and events the page listens for** with literal names: `Godot.onState('hud', ...)`, `Godot.onEvent('toast', ...)` (a string literal, not a variable). The editor reads them to offer a sample-state template.
8. **Provide sample state for every page that shows Godot values**, so the user can design it with realistic numbers: create `<ui folder>/.webui-edit/<page name>.json` (and an empty `.gdignore` in that `.webui-edit` folder), for example `ui/.webui-edit/hud.json`:
   ```json
   { "states": { "hud": { "health": 70, "max_health": 100 } },
     "events": [ { "name": "toast", "payload": { "text": "Level 1" } } ] }
   ```
   It must match exactly what `ui.set_state(...)` / `ui.emit_event(...)` send. Never read it from page code or ship it; the export plugin skips hidden folders.
9. **Show the screen in the scene editor with a `WebUIScreen` node** (optional, editor-only, see `references/webui-screen.md`): add one to a scene that shows a page and set its `page`, so the scene is not an empty canvas and says which page it uses. It never renders anything at runtime.
10. **Say so when a page is not editable.** If you had to break a rule above (a generated DOM, inline styles, script-built text), tell the user which parts they cannot tweak in the dock and why.

Details, limits and examples: `references/visual-editor.md`.

## 5. Touch, Android and desktop (summary)

- Android Back quits the game unless you take it over: set `handle_back_button = true` on the overlay, close page-owned things with `Godot.onBack(fn)` (return `true` when used), and decide the rest in the `back_requested` handler (pause, previous scene, quit). Not verified on a device.
- Touch mode defaults to `AUTO`: the overlay takes every touch until the page calls `Godot.touchRegions()`; then only elements marked `data-webui-touch` take touches and the rest reaches the game. Use `MODAL` for full-screen menus. Details and limits: `references/touch-and-runtime.md`.
- Android is the only supported runtime. The desktop preview (editor only) is a development aid: mouse and keyboard only, no touch pass-through, different web engine, different security. Never treat "works in the preview" as "works on the device".
- In the Android WebView, `localStorage`/DOM storage is disabled, `eval`/`new Function` are blocked by the CSP, popups and external navigation are blocked, zoom is off, and the page cannot blur the game behind it (`backdrop-filter`). Keep persistence in Godot.
- Recovery after a WebView renderer crash is best effort and untested on a device. Pause/resume, orientation changes and pass-through with a game that reads touches are not verified on a device.

## 6. Setup and preview (what to tell the user)

- New project: `references/new-project.md` has the install commands and the prompts to give an agent. Short version, run from the WebUI repository: `python tools/setup.py add-to-project PATH --enable-plugin --with-skill` (then, in the editor: Install Android Build Template, Use Gradle Build on).
- Preview and visual editor: enable the plugin, open the **WebUI** dock, pick a page, **Open preview**. It needs the one-time `python tools/setup.py wry` step (an optional third-party dependency installed outside the project).
- Android: enable the plugin, install the Android build template, turn on Use Gradle Build, export. No export filter is needed for the UI.

## 7. Finish by reporting

Tell the user: which files you created or changed; how to preview (which page in the dock, the setup step if missing); which events and states the bridge now carries (names and payload shapes) and where the sample state is; which screen sizes you checked (phone portrait/landscape, tablet, wide window) and that none was a real device; which parts of the page the visual editor cannot edit and why; any behavior you could not verify (anything touching a real device); and relevant limitations from section 5. Do not claim a device behavior works unless it was run on a device.

## Reference files

- `references/api.md`: GDScript and JavaScript API, limits, signals, error codes.
- `references/animation-performance.md`: which CSS animations are cheap or costly on a phone (measured), rules, how to measure.
- `references/responsive.md`: making pages work on phones, tablets, any window size and fullscreen 2K/4K screens (with the host's UI scale): fluid units, breakpoints, safe areas, sizes to check, how it interacts with the visual editor.
- `references/ui-authoring.md`: folder layout, packaging rules, layout, assets, accessibility notes, and the resolution-independence rules (CSS-pixel control sizes, capped centered content, device pixel ratio).
- `references/visual-editor.md`: what the editor can and cannot edit, the authoring rules in detail with good and bad examples, sample state files.
- `references/webui-screen.md`: the optional `WebUIScreen` node that shows a page in the 2D scene editor: when to add it, its API, limits.
- `references/new-project.md`: installing in a new project, installing this skill in different AI agents, copy-paste prompts.
- `references/patterns.md`: tested-shape examples: button to action, state to UI, events, pages and navigation, held input, validation.
- `references/touch-and-runtime.md`: touch modes, Android vs desktop preview, lifecycle, verified vs unverified.
- `references/troubleshooting.md`: error codes and symptoms.
