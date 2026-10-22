# AGENTS.md

Guidance for AI coding agents working in this repository or writing UI for Godot WebUI. See `README.md` for the full API.

Godot WebUI shows HTML/CSS/JS as a transparent Android WebView above a Godot game. **Gameplay logic belongs in GDScript, never in the page.** Android is the only supported platform; do not add or imply iOS/desktop support.

## Writing a UI page

- Put files in a folder (e.g. `res://ui/`) with an `index.html`; use **relative** URLs. External URLs, CDNs, remote fonts and `fetch` to other hosts are blocked.
- `window.Godot` is injected before page scripts. Do not add a script tag for it.
- Transparent background (`html, body { background: transparent }`); disable selection, scrolling and default touch gestures (`touch-action: none; user-select: none; overflow: hidden`). Use `touch-action: manipulation` on pages that are scrollable-free menus.
- Mark every touchable element `data-webui-touch` and call `Godot.touchRegions()` once when using `REGIONS` mode (the default). A page that forgets this has no touchable area. Use `MODAL` mode for full-screen menus.
- Send intent, not results: `Godot.emit("jump")`, `Godot.emit("move_changed", {x, y})`. Names match `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`; payloads are plain JSON objects under 64 KB.
- Render only what Godot sends: `Godot.on("state", fn)`. Godot should resend state on every `page_ready`.
- Held inputs (joystick, hold buttons): Pointer Events with `setPointerCapture`; release on `pointerup`, `pointercancel` and `lostpointercapture`; register the release with `Godot.guard(fn)`. Track `pointerId` per control for multi-touch.
- Use `env(safe-area-inset-*)`, `%`, `vw`/`vh` and `clamp()`; do not hardcode coordinates.
- `backdrop-filter` cannot blur the game behind the overlay (separate Android surface); use gradients instead.
- The export filter must include every UI file extension used (`*.html, *.css, *.js, *.png, ...`).

## Writing GDScript for it

- The public class is `GodotWebUI` (not `WebUI`: the native plugin registers an engine singleton called `WebUI`, which shadows a class of that name on Android).
- API: `start(ui_dir, page)`, `load_page(page)`, `on(name, callable)`, `off`, `clear_handlers()`, `send(name, dict)`, `show_ui()`, `hide_ui()`, `set_touch_mode()`, `shutdown()`; signals `page_ready`, `event_received`, `error`, `console_message`, `suspended`.
- Register handlers with `on()` and validate payload types yourself. Never expose a generic "call method X" event.
- `send()` carries state (latest value per name wins). Push full state from `page_ready`.

## Repository layout

| Path | Contents |
|---|---|
| `addons/webui/` | The addon: `webui.gd` (API), `webui_bridge.gd` (validation), `webui_backend*.gd` (platform seam), `export_plugin.gd`, `web/godot.js`, `bin/*.aar` |
| `native/android/` | Gradle project, Java source of the native plugin (`com.godotwebui`) |
| `examples/playable_character/` | Demo: `main.tscn` + `app.gd` shell swapping `menu.tscn` / `game.tscn`; HTML in `ui/` |
| `templates/hud/` | Starter page |
| `tests/headless_test.gd` | Headless GDScript test |

## Conventions and gotchas

- Packaged `addons/webui/bin/*.aar` are tracked on purpose (the export plugin needs them). After changing Java code, rebuild and commit them: `cd native/android && ./gradlew copyToAddon` (Windows: `.\gradlew.bat copyToAddon`). Do not commit `native/android/**/build/`.
- `native/` has a `.gdignore`; Godot does not scan it. `/android/` at the repo root is Godot's generated build template and is git-ignored.
- `godotVersion` in `native/android/webui/build.gradle` must match the Godot export template; `WEBKIT_DEPENDENCY` in `export_plugin.gd` must match `webkitVersion` there.
- The editor rewrites `export_presets.cfg` while the project is open; don't hand-edit it with the editor running. Required settings: Gradle build on, non-resource filter `*.html, *.css, *.js`.
- Run the headless test after GDScript changes: `godot --headless --path . -s res://tests/headless_test.gd` (exit code is the number of failures). Run `godot --headless --path . --import --quit` first if class names changed.
- Nothing about touch pass-through, multi-touch, pause/resume, or orientation is verified on a device; do not state that it is.
- Keep the scope: no iOS/desktop code, no speculative features.
