# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/).

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
