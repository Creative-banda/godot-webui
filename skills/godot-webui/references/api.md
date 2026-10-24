# Godot WebUI API reference

Written from the addon source at version 0.1.0 (Godot 4.7.1). If the installed addon differs, the installed source wins: read `addons/webui/webui.gd` and `addons/webui/web/godot.js` (both start with a summary comment).

## GDScript: `GodotWebUI` (a `Node`)

Create it, add it to the scene tree, register handlers, then `start()`.

```gdscript
var ui := GodotWebUI.new()
add_child(ui)
ui.on("jump", _on_jump)
ui.page_ready.connect(_push_state)
ui.start("res://ui")            # loads res://ui/index.html
```

| Member | Behavior |
|---|---|
| `start(ui_dir: String, page := "index.html") -> bool` | Creates the overlay and loads `page` from the `res://` folder `ui_dir`. Returns `false` and emits `error` on failure. Refuses to start while another `GodotWebUI` overlay is running (`overlay_already_active`). Calling it twice on the same node only warns. The node must be in the scene tree. |
| `is_started() -> bool` | True after a successful `start()` until `shutdown()`. |
| `get_backend_name() -> String` | `"android"`, `"desktop_preview"` (editor only) or `"none"`. |
| `load_page(page: String)` | Navigates the same overlay to another page of the same folder. Resets `is_ready`, drops state/events held for the old page, and starts touch mode from modal again for `AUTO`. Needs a started overlay. |
| `on(event_name, handler: Callable)` | Registers `handler(payload: Dictionary)` for events the page sends with `Godot.emit`. Names must match `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`; names starting with `webui.` are reserved (rejected with `bad_name`). Several handlers per name are allowed. |
| `off(event_name, handler)` | Removes one handler. |
| `clear_handlers()` | Removes all handlers (use when swapping screens that register their own). |
| `set_state(name: String, payload: Dictionary)` | Persistent state for the page (`Godot.onState`). Newest payload per name wins. Before the page is ready it is held and delivered on ready. |
| `emit_event(name: String, payload := {})` | One-shot notification (`Godot.onEvent`). Delivered in order, never replayed. Before the page is ready (or while a page loads) up to 64 are held, delivered in order on ready; further ones are dropped with `event_queue_full`. Held events are dropped on `load_page`. |
| `send(name, payload)` | Deprecated alias of `set_state`. Do not use in new code. |
| `show_ui()` / `hide_ui()` | Show or hide the overlay. |
| `touch_mode` (`@export`), `set_touch_mode(mode)` | `GodotWebUI.TouchMode.AUTO` (default), `MODAL`, `REGIONS`. See `touch-and-runtime.md`. |
| `handle_back_button` (`@export`, bool, default `false`) | Take over the Android Back button. While on, Back is offered to the page first (`Godot.onBack(fn)`; return `true` to consume it) and, if the page declines or does not answer within 0.3 s, reported through `back_requested`. While on, `SceneTree.quit_on_go_back` is switched off and restored when you turn it off or `shutdown()`. Off: Back quits the app as before. Not verified on a device. |
| `shutdown()` | Destroys the overlay and releases native resources. Idempotent; also runs when the node leaves the tree. Handlers stay registered. |
| `is_ready: bool` | True once the page's handshake arrived. Stays true across reloads (each load sends a new handshake). |
| `desktop_preview_hot_reload`, `desktop_preview_devtools` (`@export`, bool) | Desktop preview only; ignored on Android. |

Payload rules for `set_state` / `emit_event`: a `Dictionary` that `JSON.stringify` can encode, encoded size at most 64 KB (`bad_payload` otherwise). Message names follow the same pattern as above (`bad_name`).

### Signals

| Signal | Meaning |
|---|---|
| `page_ready` | The page loaded and its bridge handshake arrived. Fires on every load. Send initial state here. |
| `event_received(event_name, payload)` | Every validated page event (also dispatched to `on()` handlers). |
| `error(code, text)` | Native or protocol problem. Also written with `push_warning`. See `troubleshooting.md`. |
| `console_message(level, text)` | The page's `console.*` output (Android), also printed as `[WebUI:js:LEVEL] ...`. |
| `suspended` | The app went to the background (`NOTIFICATION_APPLICATION_PAUSED`). Clear held game input. |
| `back_requested` | Android Back was pressed and the page did not use it (only with `handle_back_button`). Decide what Back does: pause, previous scene, `get_tree().quit()`. |
| `recovered` | The overlay was re-created after the WebView renderer died (best effort). State from `set_state` is restored; events are not. |

## JavaScript: `window.Godot`

Injected before any page script. Do not include `godot.js` yourself.

| Member | Behavior |
|---|---|
| `Godot.emit(name, payload?) -> boolean` | Sends an event to Godot. `name` must match `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`; `payload` must be a plain object (default `{}`; arrays and primitives are rejected); the JSON must be under 64 KB. Invalid calls log `console.error` and return `false`. Calls made before the native bridge exists are queued (up to 256). |
| `Godot.onState(name, fn)` | `fn(payload)` for every `set_state(name, ...)`. If a value for `name` already arrived, `fn` is called immediately with the latest one. |
| `Godot.onEvent(name, fn)` | `fn(payload)` for every `emit_event(name, ...)`. Never called for events that arrived before you subscribed. |
| `Godot.on(name, fn)` | Alias of `onState` (kept for compatibility). |
| `Godot.off(name, fn)` | Unsubscribes a handler registered with `on`, `onState` or `onEvent`. |
| `Godot.guard(releaseFn) -> unregister` | Calls `releaseFn(reason)` on window blur, `pagehide`, hidden visibility and native app pause (`reason` is `'blur'`, `'pagehide'`, `'hidden'` or `'pause'`). Use it to release held input. |
| `Godot.onBack(fn) -> unregister` | Android Back (with `handle_back_button`): `fn()` returns `true` to consume it (close a modal, previous screen), anything else declines and Godot gets `back_requested`. Newest handler first. |
| `Godot.touchRegions(selector?)` | Opts this page in to touch pass-through: elements matching `selector` (default `[data-webui-touch]`) receive touches, the rest of the screen reaches the game. Also tells Godot (so `AUTO` switches to pass-through). Call once. |
| `Godot.available` | `true` when the native bridge is present. |
| `Godot.preview` | `true` in the desktop development preview (not on Android). |

Handlers that throw are caught and logged; they do not break other handlers.

## Internals you must not rely on

`Godot.__receive`, `Godot.__lifecycle`, the `@e:` message-name prefix, the `webui.` event prefix (`webui.touch_regions`) and the `GodotNative` / `window.ipc` objects are bridge internals. Do not call or reimplement them.

## Limits at a glance

| Limit | Value |
|---|---|
| Message / payload size | 64 KB (JSON text) |
| Event name | `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`, not starting with `webui.` for `on()` |
| Events held before ready | 64 |
| JS queue before the bridge exists | 256 |
| Overlays at once | 1 |
| Recovery attempts | 3 per minute, then `recovery_failed` |

## `WebUIScreen` (optional node)

A `Control` that marks a scene as showing an HTML page and draws a preview of it in the 2D editor; it does nothing at runtime. Members `page`, `manual_preview`, `show_preview`, `get_ui_dir()`, `get_page_file()`, `get_status()`, `refresh_preview()`, signal `status_changed`: see `webui-screen.md`. It is not part of `GodotWebUI`'s API and `GodotWebUI` does not depend on it.

## Editor-only classes (not API: never use in game code)

The addon also contains the visual editor: `WebUIEditorDock`, `WebUIEditorModel`, `WebUIEditLink`, `WebUIEditPreview` (and `webui_edit_preview.tscn`), `WebUIScreenPreview`, `WebUIScreenInspector` (and `webui_preview_capture.tscn`, `web/capture.js`), `WebUICssPatcher`, `WebUIHtmlPatcher`, `WebUICssCatalog`, and `web/edit_mode.js` with its `webui_edit` bridge event. They run only in the Godot editor and its preview window. A game must not call them, depend on them or send `webui_edit` events. Also development-only: `GodotWebUI.desktop_preview_inject_scripts` (an `@export PackedStringArray`, empty by default, ignored on Android). See `visual-editor.md`.
