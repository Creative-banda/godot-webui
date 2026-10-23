# AGENTS.md

Guidance for AI coding agents working in this repository or writing UI for Godot WebUI. See `README.md` for the full API. **For UI work, first read `skills/godot-webui/SKILL.md`** (the agent skill: when to use WebUI, packaging, API, touch/runtime limits); the addon source remains authoritative.

Godot WebUI shows HTML/CSS/JS as a transparent Android WebView above a Godot game. **Gameplay logic belongs in GDScript, never in the page.** Android is the only supported platform; do not add or imply iOS/desktop support.

## Writing a UI page

- Put files in a folder (e.g. `res://ui/`) with an `index.html`; use **relative** URLs. External URLs, CDNs, remote fonts and `fetch` to other hosts are blocked.
- `window.Godot` is injected before page scripts. Do not add a script tag for it.
- Transparent background (`html, body { background: transparent }`); disable selection, scrolling and default touch gestures (`touch-action: none; user-select: none; overflow: hidden`). Use `touch-action: manipulation` on pages that are scrollable-free menus.
- Touch modes: the default `AUTO` is modal until the page calls `Godot.touchRegions()`; then only elements marked `data-webui-touch` take touches and the rest pass to the game. Mark every touchable element on a pass-through page. Forced `REGIONS` with no `touchRegions()` call leaves nothing touchable (the addon reports `touch_regions_missing`). Use `MODAL` for full-screen menus.
- Write pages the WebUI visual editor can edit: CSS in external `.css` files (no `<style>` blocks or `style=""`), unique ids on elements a user may tweak, static text in the HTML, plain HTML/CSS/JS, literal `Godot.onState('name', ...)` names, and sample state in `.webui-edit/<page>.json`. Rules and reasons: `skills/godot-webui/SKILL.md` section 4.
- Send intent, not results: `Godot.emit("jump")`, `Godot.emit("move_changed", {x, y})`. Names match `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`; payloads are plain JSON objects under 64 KB.
- Render only what Godot sends: persistent values with `Godot.onState(name, fn)` (late subscribers get the latest value), one-shot notifications with `Godot.onEvent(name, fn)` (never replayed). `Godot.on` is an alias of `onState`. Godot should resend state on every `page_ready`.
- Held inputs (joystick, hold buttons): Pointer Events with `setPointerCapture`; release on `pointerup`, `pointercancel` and `lostpointercapture`; register the release with `Godot.guard(fn)`. Track `pointerId` per control for multi-touch.
- Use `env(safe-area-inset-*)`, `%`, `vw`/`vh` and `clamp()`; do not hardcode coordinates.
- `backdrop-filter` cannot blur the game behind the overlay (separate Android surface); use gradients instead.
- Keep UI files in one folder (containing an `.html` file, outside `addons/`): the export plugin packages that folder's whole subtree as raw files, so images, fonts and JSON need no export filter. Reference them with relative URLs; never remote ones.

## Writing GDScript for it

- The public class is `GodotWebUI` (not `WebUI`: the native plugin registers an engine singleton called `WebUI`, which shadows a class of that name on Android).
- API: `start(ui_dir, page)`, `load_page(page)`, `on(name, callable)`, `off`, `clear_handlers()`, `set_state(name, dict)`, `emit_event(name, dict)`, `show_ui()`, `hide_ui()`, `set_touch_mode()`, `is_started()`, `get_backend_name()`, `shutdown()`; signals `page_ready`, `event_received`, `error`, `console_message`, `suspended`, `recovered`.
- Register handlers with `on()` and validate payload types yourself. Never expose a generic "call method X" event.
- `set_state()` is persistent (latest value per name wins, replayed to late subscribers); `emit_event()` is one-shot and ordered (held up to 64 until the page is ready). `send()` is the deprecated alias of `set_state()`; do not use it in new code. Push full state from `page_ready`.
- Event names starting with `webui.` are reserved for the addon (e.g. `webui.touch_regions`). Only one `GodotWebUI` overlay can run at a time.

## Repository layout

| Path | Contents |
|---|---|
| `addons/webui/` | The addon: `webui.gd` (API), `webui_bridge.gd` (validation), `webui_backend*.gd` (platform seam: interface, factory, Android, desktop preview, null), `export_plugin.gd`, `web/godot.js`, `bin/*.aar`; visual editor (editor-only): `webui_editor_dock.gd`, `webui_editor_model.gd`, `webui_css_catalog.gd`, `webui_html_patcher.gd`, `webui_edit_link.gd`, `webui_edit_preview.gd/.tscn`, `webui_css_patcher.gd`, `web/edit_mode.js` |
| `native/android/` | Gradle project, Java source of the native plugin (`com.godotwebui`) |
| `examples/playable_character/` | Demo: `main.tscn` + `app.gd` shell swapping `menu.tscn` / `game.tscn`; HTML in `ui/` |
| `docs/setup.md`, `docs/desktop-preview.md` | Setup script docs; desktop development preview docs |
| `tools/setup.py`, `tools/dependencies.json` | Setup script and pinned dependency versions/checksums |
| `skills/godot-webui/` | AI-agent skill (`SKILL.md` + `references/`) |
| `examples/minimal_hud/` | Smallest end-to-end example |
| `templates/hud/` | Starter page |
| `tests/headless_test.gd`, `tests/api_test.gd`, `tests/css_patcher_test.gd`, `tests/html_patcher_test.gd`, `tests/css_catalog_test.gd`, `tests/editor_model_test.gd`, `tests/editor_dock_test.gd`, `tests/edit_link_test.gd` | Headless GDScript tests (bridge, demo flow, desktop backend; API semantics, touch modes, guard, recovery, UI folder detection; in-place CSS patching, visual editor model and dock). `tests/edit_preview_test.gd` needs a window and godot_wry (edit mode, end to end) |

## Conventions and gotchas

- Packaged `addons/webui/bin/*.aar` are tracked on purpose (the export plugin needs them). After changing Java code, rebuild and commit them: `cd native/android && ./gradlew copyToAddon` (Windows: `.\gradlew.bat copyToAddon`). Do not commit `native/android/**/build/`.
- `native/` has a `.gdignore`; Godot does not scan it. `/android/` at the repo root is Godot's generated build template and is git-ignored.
- `godotVersion` in `native/android/webui/build.gradle` must match the Godot export template; `WEBKIT_DEPENDENCY` in `export_plugin.gd` must match `webkitVersion` there.
- The editor rewrites `export_presets.cfg` while the project is open; don't hand-edit it with the editor running. Required setting: Gradle build on. No export filter is needed: `export_plugin.gd` packages the UI folders (auto-detected, or listed in project setting `webui/export/ui_folders`) and `godot.js` itself.
- `python tools/setup.py` installs/verifies the desktop-preview dependency (outside the project) and checks the Android toolchain; run `python -m unittest discover -s tests -p "test_setup.py"` after changing it. Update `tools/dependencies.json` (version, url, sha256, size together) only after inspecting a new release.
- Folders with a `.gdignore` (`docs/`, `skills/`, `templates/`, `tools/`) are not auto-packaged by the export plugin; keep sample HTML inside such folders.
- Run both headless tests after GDScript changes: `godot --headless --path . -s res://tests/headless_test.gd` and `... -s res://tests/api_test.gd` (exit code is the number of failures). Run `godot --headless --path . --import --quit` first if class names changed.
- Nothing about touch pass-through, multi-touch, pause/resume, or orientation is verified on a device; do not state that it is.
- The desktop backend is a **development preview** that drives the optional third-party godot_wry `WebView` node; it is editor-only and must not be presented as a supported platform. Its dependency is never committed and never lives inside the project: it is loaded at run time from a user-level folder (`GDExtensionManager.load_extension`), because an extension inside `res://` gets packaged into Android exports by Godot's built-in GDExtension handling and a user export plugin cannot prevent that. `/addons/godot_wry/` and `.webui_preview/` are git-ignored. Page code can detect it with `Godot.preview`; code must not depend on preview-only behaviour.
- When changing `webui.gd`, the backend interface or `godot.js`, keep the Android path unchanged and re-test on a device.
- Keep the scope: no iOS code, no runtime desktop support, no speculative features.
