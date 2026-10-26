# World-space pages (experimental, Android)

`GodotWebUI.create_surface()` draws an HTML page onto a surface **inside the 3D world** (a terminal, a wall screen, a
diegetic menu) instead of over the whole screen. The full-screen overlay is unchanged and keeps working next to it; they
share one UI folder and the same bridge.

```gdscript
var ui := GodotWebUI.new()
add_child(ui)
ui.start("res://ui", "index.html")                       # the overlay (optional to show; it must exist)

var screen := ui.create_surface("terminal.html", Vector2i(640, 400), 10)   # page, layout size in CSS px, redraws per second
$Terminal/Screen.material_override.albedo_texture = screen.texture          # a normal ImageTexture
screen.on("terminal_action", func(p): print(p))                              # page -> Godot (Godot.emit in the page)
screen.set_state("run", {"time": 12.3})                                      # Godot -> page (Godot.onState in the page)
screen.tap(Vector2(120, 340))                                                # a tap at a page pixel (from a raycast)
```

`GodotWebUISurface` has `on/off`, `set_state`, `emit_event`, `tap`, `tap_uv`, `set_active`, `stats`, `destroy`, the signals
`page_ready`, `event_received`, `frame_updated`, and `available` (false on every platform except an Android build: all calls
are then harmless no-ops and the texture is a plain placeholder, so game code needs no branches). Inside the page the same
`window.Godot` API as the overlay exists, and `Godot.surface` holds the surface id.

Skybound (`examples/skybound/`) shows the whole loop: a terminal next to the start platform draws the live run (time, shards,
section) from `set_state`, a raycast from the crosshair turns into page pixels, Use (E, or the USE button that appears while
aiming at it) taps the page, and the page's buttons send `terminal_action` back to Godot.

## How it works

1. `WorldSurface.java` creates a second `WebView`, loads the page through the same `WebViewAssetLoader` and bridge script as
   the overlay (`addWebMessageListener`, document-start script), attaches it to the window translated off-screen, and lays it
   out at the requested size (`setInitialScale(100)`).
2. About `fps` times a second it draws the view into pixels. **Hardware mode (default):** `Surface.lockHardwareCanvas()` on an
   `ImageReader` surface, then the frame is read into a `byte[]`. **Software mode:** `View.draw()` on a `Bitmap` canvas.
3. Godot receives the `surface_frame` signal, asks for the bytes (`readSurfaceFrame`) and calls `ImageTexture.update()`.
4. Page -> Godot events use the existing message path with a surface id; Godot -> page uses `evaluateJavascript`.
5. `tap(x, y)` injects a synthetic `MotionEvent` down/up at that page pixel, so the page sees a normal touch (`pointerdown`,
   `pointerup`, `click`).

No browser engine is added: it is the same system WebView as the overlay.

## Measured (one device, Mali-G57 phone, 2408x1080, Godot 4.7.2 mobile renderer)

Skybound with one 640x400 surface at 10 Hz, game running at its normal 58-61 FPS (also 58-61 without a surface; no FPS
change was measurable). Figures come from `GodotWebUISurface.stats()`:

| | Hardware (default) | Software |
|---|---|---|
| Page draw, on the Android UI thread | about 1.8-2.5 ms (first seconds up to 4-11 ms while the page warms up) | about 19-21 ms |
| Copy into Godot (`byte[]` to `ImageTexture`) | about 0.55 ms per frame | about 0.45 ms |
| Page change to texture ready | about 12-17 ms (+ up to one 100 ms frame interval) | about 19-21 ms |
| Frames | about 10 per second | about 10 per second |

Both modes worked end to end: the texture showed the page with live state, the raycast mapped to the right page pixel
(screen centre came out as pixel 320, 216 of 640x400), and a tap on the "Back to checkpoint" button reached Godot as
`terminal_action`. Hardware mode is the default. Software mode costs a 20 ms stall of the UI thread per frame, which can
delay overlay touch handling, so use it only if hardware mode misbehaves on a device.

Cost per frame is the page's pixel count: 640x400x4 = 1 MB copied from native to Godot ten times a second.

## Limits and unresolved issues

- **One device.** Everything above was measured on a single phone. Other GPUs, Android versions and WebView versions are
  untested, and the hardware path in particular depends on `ImageReader` and `lockHardwareCanvas` behaving.
- **Taps only.** Input is a tap at a point. No drag, scroll, hover, multi-touch, text entry or keyboard on a surface. The
  page can draw a cursor from state Godot sends (Skybound does).
- **The page redraws at a fixed low rate (default 10 Hz, 1-30).** CSS animations on the page look like a low-frame-rate video.
  Animate only `transform`/`opacity` as usual. The page is not suited to fast motion, video or WebGL (the software canvas
  does not render them; hardware mode was not tested with them).
- **Memory.** A second WebView and one `ImageReader` per surface. Not measured; keep the number of surfaces small, and use
  `set_active(false)` (Skybound does when the camera is far away) so a screen nobody sees draws nothing.
- **Frame transfer is a copy.** A zero-copy path (an `ExternalTexture` fed by an `AHardwareBuffer`) exists in Godot 4.7 but
  needs native code and was not attempted, because the copy costs about 0.55 ms.
- The UI-thread draw and the main-thread copy are separate costs; the 1-2 ms hardware draw happens on the thread that also
  serves the overlay's touch events.
- Not verified: pause/resume and orientation changes with surfaces alive (the code stops drawing while the activity is
  paused and restarts afterwards), several surfaces at once, very large pages, devices where the hardware canvas fails.
- Only one overlay can run at a time, and a surface needs `start()` first because it shares the overlay's UI folder.
- `logcat` shows harmless `gralloc4: Format allocation info not found` lines when the `ImageReader` is created on this
  device.
- Android only, no iOS, and the desktop preview does not draw surfaces (`available` is false there).

## Alternatives that were considered

- **Native `SubViewport` UI in Godot** with the HTML overlay as a "focus mode" for complex screens: the fallback if a
  device cannot draw surfaces; it needs no native code but cannot reuse the HTML pages.
- **CEF / GeckoView / an embedded engine:** rejected, tens of megabytes of dependency.
