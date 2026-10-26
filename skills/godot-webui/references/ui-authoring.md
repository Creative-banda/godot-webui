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

- Be responsive (SKILL.md rule 8, details and patterns in `responsive.md`): anchor to edges with `position: fixed` plus `max(16px, env(safe-area-inset-left))`-style offsets; use `clamp()` for sizes; use `%`/`vw`/`vh`/`vmin`/flex/grid for containers; add `@media` breakpoints for height, orientation and wider screens. The host scales big screens to a ~720-px-high layout space (see "Resolution independence" below): author in ordinary CSS px for that space. The page runs on small and large phones, tablets, foldables and split-screen windows, in portrait or landscape: do not design for one device.
- Touch targets at least about 44 CSS px; leave room for thumbs at the bottom corners.
- Use CSS transitions/animations freely, but keep them cheap on low-end phones (transform and opacity over layout properties, no huge blurs). Performance on low-end devices has not been measured.
- `backdrop-filter` cannot blur the game behind the overlay: the WebView is a separate Android surface. Fake glass with gradients and borders.
- Fonts and images must be local files in the UI folder (`@font-face { src: url('fonts/ui.woff2') }`). Remote `@import`, CDNs and web fonts are blocked. **Ship the interface font**: an Android phone has Roboto and little else, so a stack that starts with `Segoe UI` or any other desktop font silently falls back and the page looks different from the preview. Put a `.woff2` (and a licence file for it) in the UI folder, declare it with `@font-face` (one face per weight you use; weights between faces fall back to the nearest) and list it first in `font-family`. The export plugin packages the whole UI folder as raw files, so the font is in the APK; check on a device with `document.fonts.check('700 16px YourFont')`.
- **Touch controls sit where thumbs rest, not in the corners.** In a two-thumb landscape grip, put the stick and the main action button in from the side edge and up from the bottom (about 6-8 % of the width in and 15-20 % of the height up), keep them clear of rounded corners and gesture bars, and use the safe-area insets as a minimum. Corner-hugging buttons are hard to hold. The Skybound example does this with `--thumb-x` and `--thumb-y`.
- The CSP on served files allows `'self'` resources, inline scripts and styles, `data:` and `blob:` URLs; it does not allow `eval`/`new Function`, other origins, frames or forms. Write ordinary scripts; avoid libraries that need `eval`.

## Resolution independence: phones to fullscreen 4K

The host scales every page the way Godot scales its own UI with `canvas_items` stretch, so you author for one comfortable layout space and the screen size only changes how much of it you get (SKILL.md rule 8). Menus, HUDs, dialogs, forms, terminals, diagrams, journals: every screen.

**Why this is done by the host, not by CSS.** A CSS pixel is a device-independent pixel: the Android WebView reports physical pixels divided by the display density, the desktop preview divides by the OS scale. A phone is about 390-450 CSS px on its short side, but a 1080p monitor is 1080, a 4K monitor at 100 % is 2160, and a large Android display or TV is similar. A page authored with phone-sized controls (14 px text, 48 px buttons) therefore looks tiny on those screens, and no media query or `clamp()` fixes it without scaling things, which every page would have to reimplement. So `GodotWebUI.ui_reference_size` (default 720, like the usual stretch base height) does it once: when the shorter side of the screen, in CSS px, is above the reference, the layout viewport is divided by `short side / reference` (at most 4x). Android uses `WebView.setInitialScale` (a real re-layout, rendered sharp), the desktop preview uses page zoom. Phones are below the reference and are not touched.

| Screen (short side in CSS px) | Scale | Layout viewport your CSS sees |
|---|---|---|
| Phone landscape, 392 | 1.0 | 875 x 392 (unchanged) |
| Tablet 800 | 1.1 | about 1280 x 720 |
| 1080p monitor, 1080 | 1.5 | 1280 x 720 |
| 1440p monitor, 1440 | 2.0 | 1280 x 720 |
| 4K at 100 %, 2160 | 3.0 | 1280 x 720 |
| 4K at 150 %, 1440 | 2.0 | 1280 x 720 |

`innerWidth`, `vw`/`vh`/`vmin`, `@media` queries and `getBoundingClientRect()` all describe this scaled viewport. Wider or taller than 16:9 gives more room on that axis, not bigger things.

Rules:

1. **Author for the layout space, in ordinary CSS px.** Text 14-24 px, buttons and inputs 44-56 px, touch targets at least 44 px, a design space up to about 1280 x 720 (and down to a 360 x 640 phone). Do not size controls by `vw`/`vh` for type or hit targets; `clamp()` and `vmin` tokens are fine because the viewport is already normalised, but do not set upper limits so small that a 720-px-high layout looks sparse.
2. **Use extra space for layout, not for bigger controls.** Wider or taller viewports get more columns, wider margins, and capped content: document-like screens take `width: min(100%, 40rem)` (a dense terminal ~1440 px) centered; spatial HUD pieces stay anchored to the edges with safe-area insets.
3. **Do not scale the page yourself.** No `zoom`, no `transform: scale()` on the root, no `html { font-size: <vw> }`, no `devicePixelRatio` arithmetic for layout, no `device-pixel-ratio` media queries: they fight the host. Read `Godot.uiScale` (also the CSS variable `--ui-scale`) only when you must, and listen to the `uiscalechange` window event if you cache sizes.
4. **Canvases size by `Godot.pixelRatio`** (physical pixels per CSS pixel; on Android `devicePixelRatio` stays at the device density and does not include the scale): `canvas.width = cssWidth * Math.min(Godot.pixelRatio, 2)`.
5. **Diagrams keep their labels.** An SVG with a `viewBox` scales its text with it: give it a `min-width` inside a horizontally scrollable wrapper on narrow viewports instead of shrinking labels below about 11 CSS px.
6. **Breakpoints for the extremes**, in the page's `.css` file: compact rules for short landscape phones (`max-height: 480px`), stacked layouts for narrow widths (`max-width: 720px`), optional multi-column arrangements for wide ones (`min-width: 1100px`). They are evaluated against the scaled viewport, so a 4K monitor takes the same branches as a 1280-wide window.
7. **Every screen, every time.** Check the page at a phone, a tablet and a large size (below) whenever you create or modify a screen.

Opting out: `ui_reference_size = 0` restores 1 CSS px = 1 dp on every screen (the pre-scale behaviour). Change the reference when the game's design space is not about 720 high (a smaller reference scales up earlier). Both are properties of the `GodotWebUI` node and can be set at run time.

How to check without devices: in the desktop preview, resize the game window to 1280x720, 1920x1080 and 2560x1440 and confirm the layout looks the same size each time with only the room around it changing (`Godot.uiScale` is logged by a probe page, or read it in the devtools console). On a connected Android phone, `adb shell wm size 2160x3840` plus `adb shell wm density 320` emulates a large display; reset with `adb shell wm size reset` and `adb shell wm density reset` (the page follows live). None of this replaces a real tablet or TV.

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
