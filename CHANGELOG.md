# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- **Overlay no longer appears over the loading screen:** `GodotWebUI.reveal_when_scene_ready` (default on, `reveal_delay_frames` = 3, `reveal_now()`, signal `revealed`). The overlay starts hidden and is shown after the game has drawn a few frames and the page's handshake arrived (at most 5 s extra), so the UI is not on top of the Godot boot splash while the scene loads. Set it to `false` for the old behaviour. Android: showing a WebView that loaded while invisible painted nothing, so `setVisible(true)` now also resumes, lays out and redraws it (checked on one phone: Skybound's menu appears right after the first game frames).
- **`WebUISurface3D` node and a desktop preview for world-space pages:** a `StaticBody3D` that shows a page of the UI folder on a 3D quad (`page`, `page_size`, `world_width`, `redraw_fps`, `active_distance`, `pause_when_offscreen`, ...), finds the running overlay by itself, accepts `on`/`set_state`/`emit_event` before it is attached, tracks the crosshair (`aim`, `use`, `use_ray`, `aimed_changed`, state `cursor`) and releases everything when freed. In the editor-run desktop preview a hidden godot_wry webview is captured with `web/capture.js` into snapshots (`surface_preview_fps`, default 4, shared by all surfaces; animations at rest, no `:hover`, synthetic taps), flagged by `GodotWebUISurface.is_preview` and a "DESKTOP PREVIEW" label. Android: at most 8 surfaces, and resuming the app no longer re-enables surfaces Godot had switched off.
- **World-space pages (experimental, Android):** `GodotWebUI.create_surface(page, size, fps)` returns a `GodotWebUISurface` whose `texture` is an HTML page drawn by an off-screen WebView (hardware canvas through an `ImageReader`, or a software `Bitmap`), with `on`, `set_state`, `emit_event`, `tap`, `tap_uv`, `set_active`, `stats`; the page uses the same `window.Godot` API. Skybound has an in-world run terminal driven by a crosshair raycast. Measured on one phone: about 2 ms draw and 0.55 ms copy per frame at 10 Hz with no measurable FPS change. Limits (taps only, one device, low redraw rate) in `docs/world-space.md`.
- Fixed: Android plugin feature detection used `has_method`, which is false for every Java plugin method on a device, so `setUiReference` was never called from GDScript; it now uses `has_java_method`.
- **Example `examples/skybound/` (the project's main scene and primary showcase):** a first-person parkour showcase with a full HTML interface (menu, HUD, pause, settings, results with medals, how to play), 3D markers projected from Godot, touch controls with a swipe look zone, Android Back handling, and a bot test that tries every jump of the course.
- **Resolution-independent UI:** `GodotWebUI.ui_reference_size` (default 720, `0` = off). On screens whose shorter side is above it the page is laid out at a proportionally larger scale (at most 4x), like Godot's `canvas_items` stretch, so a 1080p/1440p/4K screen gives the CSS a ~720-px-high layout space instead of a tiny interface; phones are untouched. Android: `WebView.setInitialScale` (real re-layout, live on rotation, resize and density change; touch regions use the same factor). Desktop preview: page zoom. Pages can read `Godot.uiScale` / `Godot.pixelRatio` (CSS variable `--ui-scale`, window event `uiscalechange`). The skill and UI-authoring references now tell authors to design for that layout space and never scale the page themselves.
- MIT `LICENSE`.
- **Setup:** `tools/setup.py` (Python 3.8+, standard library) installs the pinned, SHA-256-verified godot_wry desktop-preview dependency into a user-level folder outside the project (idempotent, with repair, rollback and clear errors), checks the Android toolchain (JDK, SDK, export templates, build template, keystore, preset) and explains what is missing, copies the addon into another project (`add-to-project`, optional plugin enabling and skill install). Pins live in `tools/dependencies.json`; documented in `docs/setup.md`; tested by `tests/test_setup.py`. Verified end to end on one Windows machine; macOS and Linux paths are untested.
- **AI-agent skill:** `skills/godot-webui/` (`SKILL.md` plus `references/`) covering when to use WebUI, project inspection, UI layout and packaging, the exact API, touch and runtime limits, patterns, troubleshooting and verification status.
- `examples/minimal_hud/`: a small end-to-end example (button to action, state to UI, one-shot events) with tests in `tests/api_test.gd`.
- The export scan skips folders containing a `.gdignore` (the repository's `docs/`, `skills/`, `templates/` and `tools/` now have one so their sample files are never packaged).
- The factory uses the null backend when the display server is headless, so running the headless tests with godot_wry installed does not try to create a webview.
- **Export packaging:** the export plugin packages the UI folders (auto-detected: any folder outside `addons/` containing an `.html` file, or the project setting `webui/export/ui_folders`) and `godot.js` as raw files, so the manual "non-resource files" export filter is no longer needed. It skips the normal export of those files to avoid duplicates, and reports misconfiguration in the export log (no UI folder found, invalid folder setting, *Use Gradle Build* off, godot_wry inside the project).
- **API:** `GodotWebUI.set_state()` (persistent, replayed) and `emit_event()` (one-shot, ordered, never replayed, up to 64 held until ready); JS `Godot.onState()` and `Godot.onEvent()`. `send()` and `Godot.on()` remain as compatible aliases of the state variants.
- **Touch modes:** `TouchMode.AUTO` (new default): modal until the page calls `Godot.touchRegions()`, which now also tells Godot. Forced `REGIONS` reports `touch_regions_missing` if the page never opts in.
- **Resilience:** duplicate-overlay guard (`overlay_already_active`), `is_started()`, and best-effort re-creation of the overlay when the native layer reports `render_process_gone` (`recovered` signal, `recovery_failed` after 3 tries a minute). Untested on a device.
- Clearer runtime errors when the UI or `godot.js` was not packaged.
- `tests/api_test.gd` (fake-backend tests for the above and UI-folder detection).

- Desktop development preview (editor only): `WebUIBackendDesktop` and `WebUIBackendFactory` drive the optional godot_wry `WebView` node so the UI can be used inside the running game with F5/F6, with hot reload of UI files. Not a supported runtime; documented in `docs/desktop-preview.md`. Verified on one Windows 11 machine with godot_wry v0.2.0 and Godot 4.7.1 (UI over the game, transparency, messaging, hot reload); macOS/Linux and keyboard behaviour unverified.
- `GodotWebUI.get_backend_name()`, `desktop_preview_hot_reload`, `desktop_preview_devtools`, and `Godot.preview` in the page.
- `godot.js` adapts to `window.ipc` when the Android bridge object is absent.

### Fixed
- Demo keyboard controls (arrows/A-D move, Space/Up/W jump, X/J attack) stopped working in the desktop preview because the overlay takes keyboard focus and its forwarded key events are not visible to `Input` polling; the demo player now reads key events.

### Changed
- **Desktop preview dependency location:** godot_wry is now loaded at run time from a user-level folder (`OS.get_data_dir()/godot_webui/godot_wry`, or `$GODOT_WEBUI_WRY`) instead of the project. An extension inside the project is packaged into Android exports by Godot's built-in handling (and fails them when its Android libraries are missing), which an export plugin cannot prevent. New error codes: `desktop_preview_load_failed`, `desktop_preview_needs_restart`.
- The default touch mode changed from `REGIONS` to `AUTO`. Projects that set a mode explicitly are unaffected; projects relying on the default get modal behaviour until their page calls `Godot.touchRegions()`.
- `WebUIBackend.create()` takes an optional `host` node; backend selection moved into `WebUIBackendFactory` (Android behaviour unchanged).

## [0.1.0] - Unreleased

Initial implementation. Android only.

### Added
- Native Android plugin (`native/android/`): transparent full-screen `WebView` overlay, local content via `WebViewAssetLoader`, blocked non-local requests and navigation, a single origin-restricted message listener, touch pass-through by page-reported regions, and pause/resume/destroy handling.
- Godot addon (`addons/webui/`): `GodotWebUI` public API, `WebUIBridge` message validation, backend interface with Android and null backends, and an export plugin that adds the AAR and `androidx.webkit` to Gradle-based Android exports.
- Browser API `window.Godot` (`addons/webui/web/godot.js`): `emit`, `on`, `off`, `guard`, `touchRegions`.
- Packaged plugin libraries `addons/webui/bin/WebUI-debug.aar` and `WebUI-release.aar`, built against Godot 4.7.1.
- Demo `examples/playable_character/`: HTML main menu, level select, settings, stats and about screens; HTML HUD with joystick, jump, attack, health bar and pause; Godot-owned gameplay, settings and stats.
- Starter page `templates/hud/index.html`, `tests/headless_test.gd`, `README.md`, `AGENTS.md`.

### Known scope and gaps
- iOS and desktop are not implemented.
- Verified on one Android device only; touch pass-through, multi-touch across game and HUD, pause/resume, orientation changes, release builds and asset-heavy UIs are unverified. See the README's Limitations section.
