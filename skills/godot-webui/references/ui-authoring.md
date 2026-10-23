# Authoring a WebUI interface

## Folder layout

```
res://ui/                      one UI folder (name is yours; it only needs an .html file inside)
  index.html                   page loaded by start("res://ui") (or the name you pass)
  menu.html, hud.html          more pages in the same folder, reached with load_page("menu.html")
  style.css, hud.js            relative links
  img/logo.png, fonts/ui.woff2 any assets, any depth
```

Keep one UI folder per game unless there is a reason not to. `start(ui_dir, page)` serves exactly that folder; `load_page()` navigates inside it.

## What gets packaged for Android (from `export_plugin.gd` and `webui_export_scan.gd`)

The addon's export plugin (active only for Android exports) does this at export time:

1. **Folders:** if the project setting `webui/export/ui_folders` (array of `res://` folders) is non-empty, those folders are used (invalid or missing entries are reported in the export log). Otherwise it auto-detects every folder that directly contains an `.html`/`.htm` file, scanning from `res://` but skipping `addons/`, `android/`, `native/`, hidden folders (name starts with `.`) and any folder that contains a `.gdignore` file. HTML files directly in `res://` are not packaged (a warning explains why); move them into a folder.
2. **Files:** everything in those folders and below is packaged **as raw files** (HTML, CSS, JS, JSON, PNG/JPG/SVG/WebP, TTF/OTF/WOFF2, audio/video...). Godot's `.import` and `.uid` files are skipped. Packaged files are not re-imported or converted.
3. **Bridge script:** `res://addons/webui/web/godot.js` is always packaged.
4. The export log prints `WebUI export: packaged N UI file(s) from ...` and reports problems. Read it when something is missing at runtime.

Consequences for you: do not add `*.html, *.css, *.js` to the export preset's non-resource filter (not needed; harmless if present). Put sample pages, docs and mockups that contain `.html` outside the game folder or next to a `.gdignore`, or they will ship in the APK. Do not store large unused assets in the UI folder; at runtime the whole folder is copied to `user://` once per `start()` on Android, so size adds startup time.

Verified: real debug Android exports (Gradle and non-Gradle) of isolated copies packaged the demo UI, an imported PNG, an SVG, a TTF and a JSON file correctly. Not verified: that those assets load and render inside the WebView on a device.

## Page template

```html
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <!-- window.Godot already exists here -->
  <script src="app.js"></script>
</body>
</html>
```

```css
html, body { margin: 0; height: 100%; overflow: hidden; background: transparent;
             touch-action: none; user-select: none; -webkit-user-select: none; }
```

Transparent `html`/`body` is what lets the game show through. A full-screen opaque panel is fine for pause menus. Menus that never need the game to receive touches can use `touch-action: manipulation` instead of `none`.

## Layout for games

- Anchor to edges with `position: fixed` plus `max(16px, env(safe-area-inset-left))`-style offsets; use `clamp()` for sizes; use `%`/`vw`/`vh`/flex/grid for containers. Phones are usually landscape for games; do not assume one resolution.
- Touch targets at least about 44 CSS px; leave room for thumbs at the bottom corners.
- Use CSS transitions/animations freely, but keep them cheap on low-end phones (transform and opacity over layout properties, no huge blurs). Performance on low-end devices has not been measured.
- `backdrop-filter` cannot blur the game behind the overlay: the WebView is a separate Android surface. Fake glass with gradients and borders.
- Fonts and images must be local files in the UI folder (`@font-face { src: url('fonts/ui.woff2') }`). Remote `@import`, CDNs and web fonts are blocked.
- The CSP on served files allows `'self'` resources, inline scripts and styles, `data:` and `blob:` URLs; it does not allow `eval`/`new Function`, other origins, frames or forms. Write ordinary scripts; avoid libraries that need `eval`.

## Separation of concerns

| Page | Godot |
|---|---|
| Layout, styling, animation, hover/press feedback | Authoritative values (health, ammo, inventory, settings) |
| Capturing touch/pointer input and turning it into named intents | Deciding what an intent does; validating payloads |
| Rendering state it is given; local-only UI state (open tab, selected card) | Persistence (saves, settings files); the page has no `localStorage` on Android |
| Cosmetic reactions to one-shot events | Cooldowns, costs, rules, rewards |

The page may predict cosmetically (a press animation) but must not decide outcomes. If the page needs a derived number (percent, ratio), compute it from Godot's values at render time.

## Multiple screens

Either one HTML file with several sections toggled in JavaScript (fast, no reload), or several HTML files reached with `ui.load_page("menu.html")` (each load re-runs the page and fires `page_ready`; the demo does this; the first WebView load took about 0.8 s on the one device measured, later loads were not measured on a device). Navigation between sections inside one page is browser-side; only actions that matter to the game (`menu_play`, `settings_changed`) go through the bridge. If a screen switch also changes Godot scenes, call `clear_handlers()` before registering the next screen's handlers.

First-visit hitch: a `display:none` section has no style, layout or paint until it is shown, and the GPU shaders for its shadows, gradients and filters are compiled the first time it is drawn. If a section with heavy effects hitches on its first visit only, draw it once invisibly while idle (see `warmScreens()` in `examples/playable_character/ui/menu.js`). Only do this for sections that show the symptom: it costs a few frames at idle. Not yet confirmed on a device.

## Accessibility and localization

Not provided by the addon. Use real `<button>` elements, readable contrast and sizes. For localization, let Godot own the active language and send translated strings or a language code as state; the page should not hardcode strings it cannot change. Screen reader behavior, on-screen keyboard/IME for text inputs and gamepad focus navigation have not been implemented or verified.
