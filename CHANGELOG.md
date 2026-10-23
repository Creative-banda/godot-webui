# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
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
