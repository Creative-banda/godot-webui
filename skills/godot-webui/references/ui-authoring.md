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

- Be responsive (SKILL.md rule 8, details and patterns in `responsive.md`): anchor to edges with `position: fixed` plus `max(16px, env(safe-area-inset-left))`-style offsets; use `clamp()` for sizes; use `%`/`vw`/`vh`/`vmin`/flex/grid for containers; add `@media` breakpoints for height, orientation and wider screens. The page runs on small and large phones, tablets, foldables and split-screen windows, in portrait or landscape: do not design for one device.
- Touch targets at least about 44 CSS px; leave room for thumbs at the bottom corners.
- Use CSS transitions/animations freely, but keep them cheap on low-end phones (transform and opacity over layout properties, no huge blurs). Performance on low-end devices has not been measured.
- `backdrop-filter` cannot blur the game behind the overlay: the WebView is a separate Android surface. Fake glass with gradients and borders.
- Fonts and images must be local files in the UI folder (`@font-face { src: url('fonts/ui.woff2') }`). Remote `@import`, CDNs and web fonts are blocked.
- The CSP on served files allows `'self'` resources, inline scripts and styles, `data:` and `blob:` URLs; it does not allow `eval`/`new Function`, other origins, frames or forms. Write ordinary scripts; avoid libraries that need `eval`.

## Resolution independence: phones to fullscreen 4K

WebUI pages must stay readable and usable from a small phone up to a fullscreen 2K/4K desktop window (SKILL.md rule 8) — menus, HUDs, dialogs, forms, terminal shells, puzzle diagrams, journals, completion screens: every screen. Two facts drive the rules:

- **Physical resolution ≠ CSS viewport.** Browsers and the Android WebView map the screen to CSS pixels through device pixel ratio and OS display scaling. A 4K monitor at 150 % scaling is a ~2560-px-wide *CSS* viewport; an Android WebView already reports CSS pixels for its density. Never write CSS against physical pixels, never assume the CSS viewport equals the screen's pixel count, and do not use `device-pixel-ratio` media queries.
- **Viewport-proportional sizing breaks at the extremes.** Type and controls sized in raw `vw`/`vh` grow a phone layout into giant text on a 4K display (2.2vw ≈ 84 px at 3840 px) or, authored on a large display, shrink to nothing on a phone. The user gets more *space* at larger sizes — not proportionally bigger (or smaller) everything.

Practical rules:

1. **Controls in CSS pixels or double-bounded `clamp()`.** Text lands around 13–22 px, buttons and inputs 40–48 px tall, touch targets ≥44 CSS px, at every viewport size. A viewport-driven scaling token is acceptable only when clamped at both ends (`--u: clamp(8px, 1.4vmin, 16px)`); never raw `vw` for font sizes or hit targets.
2. **Content capped and centered.** Document-like screens (menus, terminals, dialogs, journals, results) take `width: min(100%, <cap>)` centered with `margin: 0 auto` — e.g. 40rem for a dialog, ~1440px for a dense terminal shell. On a 4K display they gain margins, not stretched rows. Cap inner text columns too (~70–90 ch). Spatial HUD elements stay edge-anchored instead.
3. **Extra space is used, not filled.** Larger viewports get more padding, wider margins or extra columns (`grid-template-columns: repeat(auto-fit, minmax(160px, 1fr))`) — never proportionally larger type.
4. **Diagrams keep their labels.** An SVG drawing with a `viewBox` scales its text with it: give it a `min-width` inside a horizontally scrollable wrapper on narrow viewports instead of shrinking labels below ~11 CSS px, and cap its growth on wide ones. Check that click targets inside a scaled diagram stay ≥44 CSS px at the *worst* viewport, not the average one.
5. **Breakpoints for the extremes**, in the page's `.css` file: compact rules for short landscape phones (`max-height: 480px`), stacked/wrapped layouts for narrow widths (`max-width: 720px`), and optional multi-column arrangements for wide windows (`min-width: 1100px`).
6. **Every screen, every time.** Apply the above when creating *or modifying* any WebUI screen; a page that is correct at 1280×720 but tiny at 2560×1440 (or scrolls its diagram into unreadability at 390×740) is not done.

Verify by resizing the desktop preview (or the game window) to at least a ≥2560-px-wide size and a phone-width size and checking the review checklist in `responsive.md`.

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

## Editor-friendly pages

The user adjusts designs in the WebUI dock of the Godot editor. Write pages so that works: CSS in external `.css` files (no `<style>` blocks, no `style=""`), unique ids on elements the user may tweak, static text in the HTML, plain HTML/CSS/JS with no DOM-generating framework, literal `Godot.onState('name', ...)` names, and a sample-state file `.webui-edit/<page>.json` (plus an empty `.gdignore` in that folder) so the page can be designed with realistic values. The rules, reasons and examples are in `SKILL.md` section 4 and `visual-editor.md`. The `.webui-edit` folder is hidden, never exported, and must not be read by page code.
