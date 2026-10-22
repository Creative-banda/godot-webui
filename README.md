# Godot WebUI

Build game HUDs and menus with HTML, CSS and JavaScript while Godot keeps owning gameplay and game state.

Godot WebUI places a native Android `WebView` above your game as a transparent, touch-interactive overlay and connects it to GDScript through a small, validated message bridge.

> **Status: early (0.1.0), Android only.** There is no iOS or desktop backend. See [Limitations](#limitations) for what is and isn't verified.

## Overview

Web technologies are good at UI: layout, animation, typography, gradients and responsive design are cheap there and laborious with Godot `Control` nodes. AI coding agents are also fluent in HTML/CSS/JS. This addon lets you use that for game interfaces without moving any gameplay into JavaScript:

- **Page → Godot:** the page sends named events with JSON payloads (`Godot.emit("jump")`). Godot decides what they mean.
- **Godot → page:** Godot sends named state (`send("state", {...})`) and the page renders it.

This differs from rendering HTML into a texture: the overlay is a real Android view. It receives real touches, multi-touch, pointer events and CSS `:active` states, and Godot continues to render the game behind it.

## Features

Implemented in the current code:

- Native Android `WebView` overlay, full-screen and transparent, managed by an Android plugin (Java, Godot plugin v2).
- Local HTML loading from a `res://` folder through `WebViewAssetLoader`; non-local requests and navigation are blocked.
- JavaScript → GDScript events with name and payload validation, a size limit (64 KB) and error signals.
- Godot → JavaScript named state updates; updates sent before the page is ready are held and delivered when it is.
- Touch handling helpers: a pointer-capture pattern, and `Godot.guard()` to release held input on blur, page hide and app pause.
- Optional touch pass-through: only elements marked `data-webui-touch` receive touches, the rest reach the game.
- Page navigation within one UI folder (`load_page`), show/hide, shutdown, and a `suspended` signal for app pause.
- Example: a physics character with an HTML menu (levels, settings, stats, about) and an HTML HUD (joystick, jump, attack, health, pause).
- Starter page in `templates/hud/index.html`.

Not every item has been verified on real devices; see [Limitations](#limitations).

## Architecture

```mermaid
flowchart LR
    subgraph Page["HTML / CSS / JS (WebView)"]
        UI["Your UI"] --- GJS["Godot JS API<br/>(godot.js, injected)"]
    end
    subgraph Native["Android plugin (Java)"]
        WV["OverlayWebView<br/>+ WebViewAssetLoader"] --- PL["WebUIPlugin<br/>message listener"]
    end
    subgraph GD["Godot (GDScript)"]
        BE["WebUIBackendAndroid"] --> BR["WebUIBridge<br/>(validation)"] --> API["GodotWebUI<br/>(public API)"] --> GAME["Your game"]
    end
    GJS -- "postMessage(JSON)" --> PL
    PL -- "signal: message" --> BE
    API -- "send(name, state)" --> BE
    BE -- "sendMessage" --> PL
    PL -- "evaluateJavascript" --> GJS
```

| Part | Responsibility |
|---|---|
| **Web UI** | Rendering, animation, layout, buttons, joysticks, browser-side UI state |
| **Godot** | Movement, physics, rules, authoritative health/inventory/settings, handling page events |
| **Android plugin** | Creating the WebView, local content serving, touch routing, the bridge, lifecycle and cleanup |
| **Bridge** | JSON messages. Native checks size and type, `WebUIBridge` (GDScript) validates the schema. Pages can only trigger handlers you registered with `on()` |

Security measures in the native layer: a single `WebMessageListener` limited to the local origin and main frame (no `addJavascriptInterface`), network loads blocked, file and content access off, a CSP on served files, and no `INTERNET` permission requirement.

## Requirements and compatibility

| | |
|---|---|
| Godot | **4.7.1** (the native AAR is built against `org.godotengine:godot:4.7.1.stable`). Other versions are untested. |
| Platform | **Android only.** iOS and desktop are not implemented. |
| Android | `minSdk` 24 (set by the plugin). Needs an Android System WebView that supports `WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT`; otherwise an `error("webview_too_old", …)` is emitted. |
| Export | Gradle-based Android export (*Use Gradle Build* plus the Android build template). |
| Building the native plugin (optional) | JDK 17, Android SDK (platform 35, build-tools 35.0.1), internet access for Gradle. Uses Gradle 8.11.1 (wrapper) and Android Gradle Plugin 8.6.1; `androidx.webkit` 1.12.1 is added to exports automatically. |
| Toolchain confirmation | The versions above were used for the existing build. Whether other JDK/AGP/Gradle combinations work is unconfirmed. |

## Installation

The packaged plugin libraries are already in the repository, so you do **not** need to build the native plugin to use the addon.

1. Copy the folder `addons/webui/` into your project's `addons/` folder, keeping this layout:
   - `addons/webui/*.gd` and `plugin.cfg`
   - `addons/webui/web/godot.js`
   - `addons/webui/bin/WebUI-debug.aar` and `WebUI-release.aar`
2. Enable the plugin: *Project → Project Settings → Plugins → godot-webui*. It registers the export plugin that adds the AAR (and `androidx.webkit`) to Android exports.
3. Install the Android build template: *Project → Install Android Build Template…* (this creates `android/build`).
4. Configure the export preset (*Project → Export → Android*):
   - **Options → Gradle Build → Use Gradle Build:** on.
   - **Resources → Filters to export non-resource files/folders:** include your UI file types, e.g. `*.html, *.css, *.js` (add `*.png, *.svg, *.woff2, …` if you use them). Godot does not export these automatically.
5. Set up the Android SDK, JDK and keystore in *Editor Settings → Export → Android*, and install the matching export templates.
6. Put your UI in a folder such as `res://ui/` with an `index.html`, and use `GodotWebUI` as shown below.

**Native plugin source vs. packaged artifacts:** `native/android/` is the Java/Gradle **source**. `addons/webui/bin/*.aar` are the **packaged artifacts** that the export plugin includes in your APK. Rebuild them only if you change the Java code (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## Quick start

GDScript:

```gdscript
extends Node

var ui := GodotWebUI.new()
var health := 100

func _ready() -> void:
    add_child(ui)
    ui.error.connect(func(code: String, text: String) -> void: printerr(code, ": ", text))
    ui.page_ready.connect(_push_state)          # fires on every page load
    ui.on("jump", func(_payload: Dictionary) -> void: print("jump requested"))
    ui.on("move_changed", func(p: Dictionary) -> void: print(p.get("x"), " ", p.get("y")))
    ui.start("res://ui")                         # loads res://ui/index.html

func _push_state() -> void:
    ui.send("state", {"health": health, "max_health": 100})
```

`res://ui/index.html`:

```html
<!doctype html>
<html>
<head>
  <meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no, viewport-fit=cover">
  <style>html, body { margin: 0; background: transparent; touch-action: none; }</style>
</head>
<body>
  <div id="hp">HP --</div>
  <button id="jump" data-webui-touch>JUMP</button>
  <script>
    Godot.touchRegions();   // only [data-webui-touch] elements take touches
    document.getElementById('jump').addEventListener('pointerdown', () => Godot.emit('jump'));
    Godot.on('state', (s) => { document.getElementById('hp').textContent = 'HP ' + s.health; });
  </script>
</body>
</html>
```

`window.Godot` is injected automatically; do not add a script tag for it.

### GDScript API (`GodotWebUI`)

| Member | Purpose |
|---|---|
| `start(ui_dir, page = "index.html") -> bool` | Create the overlay and load a page. Returns `false` and emits `error` on failure. |
| `load_page(page)` | Navigate to another page of the same folder. |
| `on(name, callable)`, `off(name, callable)`, `clear_handlers()` | Register handlers; the handler receives the payload `Dictionary`. |
| `send(name, payload: Dictionary)` | Send named state to the page. Before the page is ready, only the newest payload per name is kept. |
| `show_ui()`, `hide_ui()` | Toggle visibility. |
| `set_touch_mode(GodotWebUI.TouchMode.MODAL` or `REGIONS)`, `touch_mode` | `MODAL`: the WebView takes all touches. `REGIONS` (default): only `data-webui-touch` elements do. |
| `shutdown()` | Destroy the WebView (also done on `_exit_tree`). |
| `is_ready` | `true` once the page's handshake has arrived. |
| Signals | `page_ready`, `event_received(event_name, payload)`, `error(code, text)`, `console_message(level, text)`, `suspended` |

### JavaScript API (`Godot`)

| Member | Purpose |
|---|---|
| `Godot.emit(name, payload?)` | Page → Godot. Name matches `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`; payload is a plain object under 64 KB. |
| `Godot.on(name, fn)`, `Godot.off(name, fn)` | Receive state from Godot. If a value already arrived, `fn` is called with the latest one. |
| `Godot.guard(releaseFn)` | Runs `releaseFn` on window blur, page hide and native app pause. Returns an unregister function. |
| `Godot.touchRegions(selector?)` | Enables pass-through regions (default selector `[data-webui-touch]`). |
| `Godot.available` | `true` if the native bridge is present. |

To avoid stuck input, use Pointer Events with `setPointerCapture`, release on `pointerup`, `pointercancel` and `lostpointercapture`, and register the release with `Godot.guard()`. The demo's `ui/hud.js` shows the pattern.

## Example project

The repository root is a Godot project whose main scene is the demo (`examples/playable_character/main.tscn`).

1. Open the project in Godot 4.7.1.
2. Confirm the plugin is enabled and the Android build template is installed (see [Installation](#installation)). The included `export_presets.cfg` has *Use Gradle Build* on and the UI file filter set, but the editor can overwrite this file while it is open, so check *Project → Export*.
3. Connect an Android device with USB debugging and use *Run on device* (or export an APK).

What the demo shows:
- An HTML main menu (Play, Levels, Settings, Stats, About) over a Godot-drawn background. Settings and stats are owned by Godot and displayed by the page.
- An HTML HUD with a joystick, jump, attack (press and release), a Godot-driven health bar, and a "Hurt me" button that asks Godot to apply damage. A hazard in the level damages the player from the game side, and a pause card pauses the game in Godot.

On desktop, `GodotWebUI.start()` reports `unsupported_platform`; the character can still be moved with the arrow keys and Space.

## Project structure

```
addons/webui/                  Godot addon
  webui.gd                     GodotWebUI: public API
  webui_bridge.gd              Message validation/encoding (no platform code)
  webui_backend*.gd            Backend interface, Android backend, null backend
  export_plugin.gd             Adds the AAR and androidx.webkit to Android exports
  web/godot.js                 Browser-side API, injected into the page
  bin/*.aar                    Packaged native plugin (debug and release)
native/android/                Gradle project: Java source of the native plugin
examples/playable_character/   Demo scenes, scripts and HTML UI (ui/)
templates/hud/                 Starter HTML page
tests/headless_test.gd         Headless GDScript test
AGENTS.md                      Guidance for AI coding agents working in this repo
```

## Limitations

- **Android only.** No iOS or desktop backend exists.
- **Verified:** the GDScript loads in Godot 4.7.1; `tests/headless_test.gd` passes on desktop with the null backend; the native plugin compiles to AARs; and the demo has been run on one Android device, where the overlay, transparency, input, state updates and menu/game navigation worked.
- **Not verified on device:** touch pass-through to a game that handles its own touches, a game-layer finger together with a HUD finger, pause/resume with held input, orientation changes, repeated page or scene transitions, release builds, image/font/audio assets, notch and safe-area behaviour, and low-end device performance.
- **Compatibility:** only Godot 4.7.1 has been used. Release export and minification have not been tried.
- **Touch pass-through** is decided at touch-down from element bounding boxes reported by the page (refreshed about every 200 ms), not per pixel. A gesture that starts on the HUD stays with the WebView.
- **One overlay at a time:** the native plugin holds a single WebView.
- **No recovery** if the WebView renderer process dies (an `error` is emitted).
- **Not implemented:** Android Back button handling, text input and on-screen keyboard handling, gamepad or focus navigation inside the page, and HTML preview on desktop.
- **State vs. events:** `send()` is designed for state. The page keeps the latest value per name and replays it to late subscribers, so it is not suited to one-shot events.
- **Iteration:** UI changes currently need an export to a device.
- **Startup:** the first WebView start took roughly 0.8 s on the tested device.
- The overlay sits above the game surface; Godot cannot draw over it. The WebView cannot blur the game behind it, so `backdrop-filter` has no effect on the game.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `WebUI error missing_script: res://addons/webui/web/godot.js could not be read` | Non-resource files were not exported. In *Export → Resources*, set the non-resource filter to include `*.html, *.css, *.js` (check for typos such as `*.js.`) and re-export. |
| `stage_failed` (a UI file cannot be read) | Same cause: add that file extension to the export filter. |
| `plugin_missing` ("Android plugin 'WebUI' not found") | Enable *Use Gradle Build*, install the Android build template, make sure the *godot-webui* plugin is enabled and `addons/webui/bin/*.aar` exist, and run through *Run on device* or an export with Gradle on. |
| `Nonexistent function 'new' in base 'JNISingleton'` | The native plugin registers a singleton named `WebUI`. Use the class `GodotWebUI`, not `WebUI`. |
| `unsupported_platform` on desktop | Expected: only Android has a backend. |
| Export settings keep reverting | The editor rewrites `export_presets.cfg` while the project is open. Change settings in *Project → Export*, not in the file. |
| `webview_too_old` | Update Android System WebView on the device. |
| `blocked_request` or `blocked_navigation` | The page tried to load a non-local URL. Everything must be served from the UI folder. |
| `Typed UAV Load Additional Formats` error in the Windows editor | Your GPU lacks a D3D12 feature. Set *Rendering → Rendering Device → Driver → Windows* to `vulkan`. Unrelated to this addon. |

## Contributing and license

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests and how to rebuild the native plugin, [SECURITY.md](SECURITY.md) for reporting vulnerabilities, and [CHANGELOG.md](CHANGELOG.md) for changes.

**License:** not yet chosen. No license file is present in this repository.
