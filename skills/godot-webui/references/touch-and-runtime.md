# Touch, runtime behavior and what is verified

## Touch modes (`GodotWebUI.touch_mode`, default `AUTO`)

| Mode | Behavior |
|---|---|
| `AUTO` (default) | Modal until the page calls `Godot.touchRegions()`. After that only the matching elements receive touches and everything else reaches the game. Every page load starts modal again, so each page opts in itself. |
| `MODAL` | The overlay always receives every touch. Use for menus, pause screens, dialogs. |
| `REGIONS` | Pass-through is always on. A page that never calls `Godot.touchRegions()` has nothing touchable, and about 3 s after the page is ready the `error` signal reports `touch_regions_missing`. Prefer `AUTO`. |

### How pass-through works (Android native code)

1. The page calls `Godot.touchRegions()` (default selector `[data-webui-touch]`). It reports the bounding boxes of matching elements (CSS pixels, viewport coordinates), again on `resize` and about every 200 ms when they change. Zero-size or hidden elements are skipped.
2. When a gesture starts, the native view checks the first pointer against those boxes (scaled by the display density). Inside a box: the WebView handles the gesture. Outside: the touch is not consumed and Android offers it to Godot's view underneath.
3. Multi-touch is **one-directional**. A second finger can land on the HUD while the first is on the game. The reverse does not work: once a finger is on a page control, Android gives every further finger to the WebView as well (a view that already receives touches is handed new pointers inside its bounds, whatever it returns), so a finger on open screen never reaches Godot while another finger holds a control. Reported on a device with a stick plus camera swipe. If a gesture must work while a control is held (camera look next to a joystick), handle it **in the page**: put a full-screen `data-webui-touch` element under the controls, track one pointer on it, and send the deltas to Godot (`examples/playable_character/ui/hud3d.js`, `look_drag`). Send fractions of the screen height so the feel does not depend on the resolution.

Rules for pages:

- Put `data-webui-touch` on every element that must be touchable (the element, not just a wrapper with `pointer-events: none` children). Decorative panels should not carry it, so the game stays touchable around them.
- For a large control (joystick) mark a generous container, not only the visible ring.
- Pause screens and dialogs that must block the game: switch the overlay to `MODAL` (`ui.set_touch_mode(GodotWebUI.TouchMode.MODAL)`) or let a full-screen element carry `data-webui-touch`.

Limits (from the implementation):

- Boxes only: a round or irregular control uses its bounding rectangle. Not per-pixel alpha.
- A gesture that started inside a box stays with the WebView even if the finger leaves it.
- Region updates lag layout changes by up to about 200 ms; fast animations of controls can briefly mismatch.
- Not verified on a device: pass-through into a game that reads touches itself (the demo game has none), a finger on the game together with a finger on the HUD, and behavior on unusual devices.

## Android runtime vs desktop development preview

| | Android (supported runtime) | Desktop preview (editor only, F5/F6) |
|---|---|---|
| Purpose | Shipping | Faster UI iteration |
| Web engine | Android System WebView | WebView2 (Windows, tested) / WebKit (macOS, untested) / WebKitGTK (Linux, untested, no transparency) |
| Input | Touch, multi-touch, pointer events | Mouse and keyboard only; no multi-touch |
| Touch modes | `AUTO`/`MODAL`/`REGIONS` as above | Not emulated: the overlay takes mouse input over the whole window and the extension also forwards mouse and keyboard to the game |
| Keyboard in Godot | Not relevant | Forwarded key events reach Godot as input events; code that polls `Input.is_action_pressed` does not see them. Read keys in `_input` |
| Security | Network, navigation and popups blocked, CSP, origin-restricted bridge | Not equivalent; external requests are not blocked |
| Lifecycle | Pause/resume, `suspended`, renderer-death recovery | None |
| Console | `console_message` signal and Godot output | Browser inspector only |
| Reload | Needs an export | Hot reload on file change |

Anything you build must be checked against the Android column. Details: `docs/desktop-preview.md` in the repository.

## Android WebView constraints that differ from a normal browser

From the native configuration (`WebUIPlugin.java`, `LocalContentHandler.java`):

- `localStorage` / `sessionStorage` / IndexedDB: DOM storage is disabled. Keep persistence in Godot.
- `eval()` and `new Function()` are blocked by the Content-Security-Policy; inline scripts and styles are allowed.
- Only the local origin loads: no CDNs, remote fonts, remote images, analytics, `fetch`/XHR to other hosts, iframes, form posts, popups or `window.open`. A blocked request is reported through `error` (`blocked_request`, `blocked_navigation`).
- Pinch zoom is off; media needs a user gesture to autoplay; geolocation, file and content access are off; no `INTERNET` permission is required.
- Pages load from `https://appassets.androidplatform.net/ui/...` served from a copy in `user://`; always use relative URLs.
- The overlay is a separate Android surface above the game: Godot cannot draw over it, and CSS cannot blur or blend with the game behind it.
- Needs a System WebView with `WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT`; otherwise `webview_too_old`.

## Lifecycle

- App to background: the plugin pauses the WebView and releases `Godot.guard()` handlers; Godot emits `suspended`. Clear held game input there.
- `shutdown()` or leaving the scene tree destroys the overlay and releases native resources. Only one overlay can exist; a second `start()` is refused.
- Renderer crash: the native layer reports `render_process_gone`; `GodotWebUI` re-creates the overlay on the same page and restores `set_state` values (not events), at most 3 times a minute, then `recovery_failed`. Best effort, depends on Android reporting the failure, **untested on a device**. Do not promise recovery to the user.
- Not implemented: Android Back button handling, text input / on-screen keyboard handling, gamepad or focus navigation inside the page, more than one overlay.

## Verification status (addon 0.1.0)

| Area | Status |
|---|---|
| Overlay shown with transparency, HUD touch input driving gameplay, state updates, menu to game navigation (first demo version) | Run on one Android device and reported working |
| Export packaging (UI folders, imported PNG, SVG, TTF, JSON, `godot.js`, native plugin classes, no godot_wry), Gradle and non-Gradle | Verified by real debug exports of isolated project copies; not run on a device |
| Desktop preview: UI over the game, transparency, messaging, hot reload, keyboard through the overlay | Verified on one Windows machine |
| Logic of state/events, touch modes, duplicate guard, recovery, UI folder detection | Headless tests with fake backends; not on the real bridge |
| `AUTO` touch mode, `set_state` / `emit_event` over the real Android bridge, overlay guard, recovery, assets inside the WebView, pass-through with a touch-reading game, multi-touch across game and HUD, pause/resume, orientation change, release builds, low-end performance | Implemented, **not verified on a device** |
| iOS, desktop as a runtime, text input / IME, gamepad navigation, Android Back button, several overlays, world-space UI | Not supported |
