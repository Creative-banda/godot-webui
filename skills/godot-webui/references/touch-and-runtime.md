# Touch, runtime behavior and what is verified

## Touch modes (`GodotWebUI.touch_mode`, default `AUTO`)

| Mode | Behavior |
|---|---|
| `AUTO` (default) | Modal until the page calls `Godot.touchRegions()`. After that only the matching elements receive touches and everything else reaches the game. Every page load starts modal again, so each page opts in itself. |
| `MODAL` | The overlay always receives every touch. Use for menus, pause screens, dialogs. |
| `REGIONS` | Pass-through is always on. A page that never calls `Godot.touchRegions()` has nothing touchable, and about 3 s after the page is ready the `error` signal reports `touch_regions_missing`. Prefer `AUTO`. |

### How pass-through works (Android native code)

1. The page calls `Godot.touchRegions()` (default selector `[data-webui-touch]`). It reports the bounding boxes of matching elements (CSS pixels, viewport coordinates), again on `resize`, on scrolling and viewport changes (rotation, soft keyboard) and about every 100 ms when they change. Zero-size or hidden elements are skipped.
2. When a gesture starts, the native view checks the first pointer against those boxes (scaled by the display density). Inside a box: the WebView handles the gesture. Outside: the touch is not consumed and Android offers it to Godot's view underneath.
3. Multi-touch is effectively **one-directional on Android**: a second finger that arrives while the WebView holds a gesture is handed to the WebView as well (observed on a device), so a finger on open screen does not reach Godot while another finger holds a control. Captured gestures are tracked **per pointer**, so lifting one finger never ends the gestures of the fingers still down (previously a shared flag could leave the first control stuck mid-gesture — fixed; the fix is code-reviewed, single-finger behavior re-verified on a device, but two simultaneous fingers still cannot be injected over adb and remain unverified). If a gesture must work while a control is held (camera look next to a joystick), handle it **in the page**: put a full-screen `data-webui-touch` element under the controls, track one pointer on it, and send the deltas to Godot (`examples/playable_character/ui/hud3d.js`, `look_drag`). Send fractions of the screen height so the feel does not depend on the resolution.

Rules for pages:

- Put `data-webui-touch` on every element that must be touchable (the element, not just a wrapper with `pointer-events: none` children). Decorative panels should not carry it, so the game stays touchable around them.
- For a large control (joystick) mark a generous container, not only the visible ring.
- Pause screens and dialogs that must block the game: switch the overlay to `MODAL` (`ui.set_touch_mode(GodotWebUI.TouchMode.MODAL)`) or let a full-screen element carry `data-webui-touch`.

Limits (from the implementation):

- Boxes only: a round or irregular control uses its bounding rectangle. Not per-pixel alpha.
- A gesture that started inside a box stays with the WebView even if the finger leaves it.
- Region updates lag layout changes by up to about 100 ms; scrolling and viewport changes re-report on the next frame. Fast animations of controls can briefly mismatch.
- Not verified on a device: pass-through into a game that reads touches itself (the demo game has none), a finger on the game together with a finger on the HUD (two simultaneous fingers cannot be injected over adb), and behavior on unusual devices. Verified on one device: REGIONS pass-through with swipe-look into the game, region alignment across menu/3D transitions.

## Back button

By default Godot quits the app on Android Back, from any page. Set `handle_back_button = true` on `GodotWebUI` to take it over: the press is sent to the page as the reserved one-shot event `webui.back`; the page's `Godot.onBack(fn)` handlers (newest first) answer, and a handler that returns `true` consumes it. If none does, or the page does not answer within 0.3 s, the `back_requested` signal fires and the game decides. Before the page is ready, or while the overlay is hidden, `back_requested` fires at once. Turning the property off or `shutdown()` restores `SceneTree.quit_on_go_back`. The addon never decides what Back means. Verified on a device (the demo takes Back over; at the main menu it declines and Godot quits).

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
- Pinch zoom is off; media (video/audio) needs a user gesture to autoplay; geolocation, file and content access are off; no `INTERNET` permission is required.
- No download handler and no file-chooser client are installed: link downloads and `<input type="file">` do nothing, and WebView permission requests (camera, microphone) are never granted. File uploads and playback of protected media are not supported; keep assets in the UI folder.
- Pages load from `https://appassets.androidplatform.net/ui/...` served from a copy in `user://`; always use relative URLs.
- The overlay is a separate Android surface above the game: Godot cannot draw over it, and CSS cannot blur or blend with the game behind it.
- Needs a System WebView with `WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT`; otherwise `webview_too_old`.

## Lifecycle

- App to background: the plugin pauses the WebView and releases `Godot.guard()` handlers; Godot emits `suspended`. Clear held game input there. Verified on a device (HOME and resume): the page keeps its state, no blank WebView, and input routing works after resume; one benign `VK_ERROR_SURFACE_LOST_KHR` while backgrounded is normal (Godot recreates the surface).
- `shutdown()` or leaving the scene tree destroys the overlay and releases native resources. Only one overlay can exist; a second `start()` is refused. A shutdown/restart cycle mid-session (the demo's benchmark) was run on a device without duplicate overlays or lost state.
- Renderer crash: the native layer reports `render_process_gone`; `GodotWebUI` re-creates the overlay on the same page and restores `set_state` values (not events), at most 3 times a minute, then `recovery_failed`. Best effort, depends on Android reporting the failure, **untested on a device** (a renderer crash cannot be triggered over adb without root). Do not promise recovery to the user.
- Soft keyboard (HTML `<input>` elements): works; verified on a device. The keyboard pans over the page (the window does not resize), so an input near the bottom can sit under it — keep inputs in the upper half, add `interactive-widget=resizes-content` to the viewport meta, or use `Godot.editText` (`api.md`), a keyboard-aware editor card pinned above the keyboard. Back dismisses the keyboard and is consumed by the IME before the app sees it. Keep persistence in Godot: nothing in the page survives a page load, and DOM storage is off.
- Not implemented: gamepad or focus navigation inside the page, more than one overlay.

## Verification status (addon 0.1.0)

| Area | Status |
|---|---|
| Overlay shown with transparency, HUD touch input driving gameplay, state updates, menu to game navigation (first demo version) | Run on one Android device and reported working |
| Export packaging (UI folders, imported PNG, SVG, TTF, JSON, `godot.js`, native plugin classes, no godot_wry), Gradle and non-Gradle | Verified by real debug exports of isolated project copies; the packaged APK was audited (UI assets present, no editor/doc folders); not run in a release build (needs a release keystore) |
| Desktop preview: UI over the game, transparency, messaging, hot reload, keyboard through the overlay | Verified on one Windows machine |
| Logic of state/events, touch modes, duplicate guard, recovery, UI folder detection | Headless tests with fake backends; not on the real bridge |
| REGIONS pass-through (swipe-look into the game), `set_state`/`emit_event` on the real bridge, repeated scene transitions, overlay shutdown/restart, soft keyboard (focus, typing, IME dismissal), background/resume with intact page state, region updates on scroll/viewport change (mechanism) | Verified on one Android device (vivo V2312, Android 15, debug build) |
| `AUTO` touch mode, overlay guard, recovery, a game-layer finger together with a HUD finger (two-finger use cannot be automated over adb), orientation change (demo exports lock landscape), release builds and minification, low-end performance | Implemented, **not verified on a device** |
| iOS, desktop as a runtime, gamepad navigation, several overlays, world-space UI | Not supported |
