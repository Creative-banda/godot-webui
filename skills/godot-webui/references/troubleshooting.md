# Troubleshooting

Errors reach GDScript through `GodotWebUI.error(code, text)` and `push_warning`. Search the code in the installed source (`grep -rn "code_name" addons/webui native/android`) when in doubt.

## Error codes

| Code | Meaning and fix |
|---|---|
| `missing_script` | `res://addons/webui/web/godot.js` unreadable. In an export, the godot-webui plugin was not enabled when exporting. Enable it (Project Settings, Plugins) and export again. |
| `bad_ui_dir` / `stage_failed` | UI folder or a file in it could not be read/copied. Packaged exports: the folder was not packaged; check the export log line `WebUI export: packaged N UI file(s) from ...`; the folder needs an `.html` file, must be outside `addons/` and have no `.gdignore`, or be listed in `webui/export/ui_folders`. In the desktop preview: `res://.webui_preview/` must be writable. |
| `bad_root` | Native side could not open the staged UI directory. |
| `plugin_missing` | Android native plugin singleton `WebUI` not found: Use Gradle Build off, build template missing, godot-webui plugin disabled, or `addons/webui/bin/*.aar` missing. |
| `unsupported_platform` | No backend on this OS / outside the editor. Only Android is a supported runtime; the desktop preview exists only when running from the editor. |
| `overlay_already_active` | Another `GodotWebUI` overlay is running. Call its `shutdown()` first. |
| `bad_name` | Invalid or reserved event/state name. Must match `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`; `webui.` is reserved for `on()`. |
| `bad_payload` | Payload not JSON-encodable or over 64 KB. |
| `bad_message` / `message_too_large` | The page sent something invalid or over 64 KB (also logged by `godot.js` with `console.error`). |
| `bad_path` | `load_page` path invalid (empty, absolute, contains `..` or `:`). |
| `event_queue_full` | More than 64 `emit_event` calls were queued while the page loaded. |
| `touch_regions_missing` | `TouchMode.REGIONS` is set but the page never called `Godot.touchRegions()`. Call it, or use `AUTO`/`MODAL`. |
| `blocked_request` / `blocked_navigation` | The page tried to load a non-local URL. Bundle the resource in the UI folder. |
| `load_failed` | The main page failed to load (wrong file name, missing file). |
| `webview_too_old` | Update Android System WebView on the device. |
| `render_process_gone` | The WebView renderer died; the overlay is re-created automatically if possible. |
| `recovery_failed` | Re-creation failed or hit the limit of 3 per minute. |
| `already_created`, `not_created`, `no_activity`, `bad_regions` | Native lifecycle/protocol misuse or malformed touch regions; usually a symptom of calling the native layer outside `GodotWebUI`. |
| `desktop_preview_missing_dependency` | godot_wry not installed in the user-level folder. Run `python tools/setup.py wry` (in the addon repository) or see `docs/desktop-preview.md`. |
| `desktop_preview_load_failed` / `_needs_restart` / `_incompatible` / `_no_host` | godot_wry present but not loadable (needs Godot 4.7+ and the library for this OS), needs a restart, is not the expected class, or `start()` ran before the node was in the tree. |

## Symptoms

| Symptom | Likely cause |
|---|---|
| Nothing appears on Android | Plugin disabled, Gradle build off, `start()` returned `false` (check `error`), or `plugin_missing`. Read the export log and logcat for `WebUI`. |
| Text on the page never updates | Godot never sent state after the page loaded: push it from `page_ready`. Or the state names differ between `set_state("hud", ...)` and `Godot.onState("hud", ...)`. |
| Page shows old values after a reload | State is not remembered across loads: resend in `page_ready`. |
| `onEvent` handler never fires | The event arrived before the page subscribed (events are never replayed), or the name differs. Use state for values the page must always know. |
| Buttons do nothing | In `AUTO`/`REGIONS`: the element lacks `data-webui-touch` or `Godot.touchRegions()` was not called, so the touch reaches the game. Or the handler name differs from `Godot.emit` name. |
| Touches go to the game when they should hit the UI | Element not marked, or the overlay is `REGIONS`/`AUTO` and the element is outside the reported boxes (just changed layout: boxes lag about 200 ms). |
| Touches are blocked from the game | Overlay is `MODAL`, or a large element carries `data-webui-touch`. |
| Joystick or button stays pressed | No release on `pointercancel` / `lostpointercapture` / `Godot.guard()`. See `patterns.md` pattern 5. |
| Works in the desktop preview, not on the device | Preview differences: mouse vs touch, no CSP/network blocking, different engine. Check for `localStorage`, `eval`, external URLs. |
| UI files missing in the APK | Export log shows the folders packaged. Folder has `.gdignore`, is under `addons/`, is in `res://` root, or `webui/export/ui_folders` excludes it. |
| Android export fails mentioning `libgodot_wry.so` | godot_wry is inside the project. Remove `res://addons/godot_wry`; it belongs outside the project. |
| Preview: keyboard does nothing in my game | The overlay has focus and its key events are injected; polling with `Input.is_action_pressed` does not see them. Handle `_input` events. |
| Export settings revert by themselves | The editor rewrites `export_presets.cfg` while the project is open; change settings in Project > Export. |
| `Nonexistent function 'new' in base 'JNISingleton'` | Used `WebUI.new()`; the class is `GodotWebUI` (the native plugin owns the singleton name `WebUI`). |
