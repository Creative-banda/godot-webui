# World-space pages (experimental)

Show an HTML page on a surface **inside the 3D world**: a terminal, a wall display, a diegetic menu. The full-screen
overlay is unchanged and keeps working next to it; both use the same UI folder, the same bridge and the same page API
(`Godot.onState`, `Godot.emit`, ...). `Godot.surface` is `''` in the overlay and the surface id in a world-space page.

> **Android is the target.** A real WebView draws the page there. On desktop there is only a **development preview**
> made of slow snapshots (see [Android and desktop](#android-and-desktop)); it is for laying out and wiring a page
> without exporting, not for judging final look or smoothness.

## The node: `WebUISurface3D`

Add a `WebUISurface3D` (a `StaticBody3D`) to a 3D scene, set `page`, and it draws that page onto a quad with a thin
collider. Start the overlay first (it can stay hidden or empty); the node finds the running `GodotWebUI` by itself.

```gdscript
# once, somewhere: the overlay that owns the UI folder
var ui := GodotWebUI.new()
add_child(ui)
ui.start("res://ui", "index.html")

# the screen: usually set up in the inspector (page, page_size, world_width), scripted here for clarity
@onready var terminal: WebUISurface3D = $Terminal

func _ready() -> void:
	terminal.on("terminal_action", func(p: Dictionary) -> void: print(p))   # page -> Godot (Godot.emit in the page)
	terminal.set_state("run", {"time": 12.3})                                # Godot -> page (Godot.onState in the page)
	terminal.aimed_changed.connect(func(aimed: bool) -> void: $UsePrompt.visible = aimed)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("use"):
		terminal.use(get_viewport().get_camera_3d())                         # tap the page where the crosshair points
```

`on()`, `set_state()` and `emit_event()` work before the node is attached: handlers are kept, the newest state per name is
replayed to the page when it is ready (and again if the page is re-attached), and one-shot events wait for the page.

| Export | Meaning |
|---|---|
| `page` | A file of the UI folder, e.g. `terminal.html`. Changing it restarts the page. |
| `page_size` | Layout size in CSS px and texture size (64..2048). 640x400 on a 2.4 m screen reads well at about 2 m. |
| `world_width` | Width in metres; the height follows the aspect ratio. |
| `redraw_fps` | Android redraw rate (1-30, default 10). The desktop preview uses `GodotWebUI.surface_preview_fps`. |
| `active_distance` | Beyond this camera distance the page is not redrawn (0 = no limit). |
| `pause_when_offscreen` | Stop redrawing while the screen is outside the camera's view (a `VisibleOnScreenNotifier3D`; it does not know about walls). |
| `auto_attach`, `ui_path` | Connect to the running overlay by itself (default), or to the `GodotWebUI` at `ui_path`; with `auto_attach` off call `attach(ui)`. |
| `unshaded`, `collider` | Emissive-looking material; the collider that `aim()`/`use()` need. |
| `auto_aim`, `aim_reach`, `send_cursor_state` | Track whether the camera's centre ray is on the screen about 10 times a second (`aimed_changed`) and send the page the state `cursor` `{aimed, x, y}` (page px) so it can draw a pointer. |
| `show_preview_label` | Show the small "DESKTOP PREVIEW" label above the screen when the page is a snapshot. |

Methods: `attach(ui)`, `detach()`, `is_attached()`, `is_preview()`, `stats()`, `on(name, callable)`, `off(...)`,
`set_state(name, dict)`, `emit_event(name, dict)`, `world_to_pixel(point)`, `aim(camera)`, `aim_ray(from, dir)`, `use(camera)`,
`use_ray(from, dir)`, `tap_pixel(px)`, `tap_uv(uv)`. Signals: `page_ready`, `page_event(name, payload)`, `aimed_changed(bool)`,
`attached`, `detached`. `use()`/`aim()` cast a physics ray from the camera along its forward direction, so a wall in front of
the screen blocks it. For a touch on the 3D view use `use_ray(camera.project_ray_origin(pos), camera.project_ray_normal(pos))`.

Pages should have an opaque background (the texture is not blended). The page is not scrollable or draggable through the
node: input is a tap at a point.

The lower-level API is `GodotWebUI.create_surface(page, size, fps)` returning a `GodotWebUISurface` (`texture`, `on`,
`set_state`, `emit_event`, `tap`, `tap_uv`, `set_active`, `stats`, `destroy`, `is_preview`, signals `page_ready`,
`event_received`, `frame_updated`, `destroyed`). The node is a convenience on top of it.

Skybound (`examples/skybound/`) uses the node for an in-world run terminal: the page shows the live run, the crosshair
selects its buttons, E / the USE button taps, and `terminal_action` comes back to Godot.

## Android and desktop

| | Android | Desktop, editor-run preview | Anywhere else |
|---|---|---|---|
| What draws the page | A real second WebView, off-screen, drawn into frames | A hidden godot_wry webview; `web/capture.js` copies the DOM into an SVG, draws a PNG | nothing |
| Rate | `redraw_fps` (default 10) | `surface_preview_fps` (default 4, 1-10), **shared by all surfaces**, one capture at a time | - |
| Cost per frame | about 2 ms draw (UI thread) + 0.55 ms copy | about 15-60 ms per capture (measured on one PC, 640x400) | - |
| CSS animations / transitions | live | **drawn at rest** | - |
| `:hover`, `:active`, focus | n/a (touch) | **not drawn** | - |
| Video, iframes, WebGL, canvases | live (video/WebGL untested) | video and iframes missing, canvases drawn as they are at that moment | - |
| Fonts / images | as the page loads them | embedded into the copy; large or unreadable assets are skipped (notes are printed once) | - |
| Taps | a real touch event (`MotionEvent`) | synthetic DOM events at that pixel (`pointerdown`/`mousedown`/`pointerup`/`mouseup`/`click`, `isTrusted` false) | - |
| Needs | the Android plugin and Gradle build | godot_wry installed, game run from the editor (see `desktop-preview.md`) | - |
| `available` / `is_preview` | true / false | true / **true** | false / false: a text label stands in, every call is a no-op |

The preview shows the **real layout and the real wiring** (state in, events out, taps) so you can build a page without a
phone. It is a series of pictures, not a live browser: do not judge animation, smoothness or final appearance from it, and
check the page on a device. `Godot.preview` is true in the page in the preview. A page reads `Godot.surface` lazily; the
surface id is injected after the page loads in the preview, so a script that reads it at start-up sees `''` there.

The preview starts after the overlay's own page has loaded (godot_wry cannot create a second webview while the first is
loading), so the first frame of a surface is a moment later than on Android. Editing the UI files reloads the surfaces
together with the overlay.

## Lifecycle, cleanup and many surfaces

- A surface exists from `create_surface` until `destroy()`, the node leaving the tree, or `GodotWebUI.shutdown()`.
  `destroyed` is emitted in each case and the node reattaches by itself (`auto_attach`) when it is added again.
- At most **8** surfaces at once on both platforms (`surface_limit` error). Page size is 64..2048 px per side.
- Android: each surface is its own WebView plus an `ImageReader`. Freeing a node destroys both; the activity pause stops all
  drawing and resume restarts **only the surfaces Godot still wants** (a surface switched off by distance or visibility stays
  off; this was a bug in the first version). Switched-off surfaces cost nothing per frame.
- Use `active_distance` and `pause_when_offscreen` (`active_distance` is off by default, `pause_when_offscreen` on) so screens nobody sees draw
  nothing; `set_active(false)` does the same by hand on a `GodotWebUISurface`.
- Desktop preview: captures are serialised across surfaces, so more surfaces mean a lower rate for each, not more work per
  frame. Hidden webviews are freed with their surface.

## How Android draws it

1. `WorldSurface.java` creates a second `WebView`, loads the page through the same `WebViewAssetLoader` and bridge script
   as the overlay, attaches it to the window translated off-screen and lays it out at `page_size` (`setInitialScale(100)`).
2. About `fps` times a second it draws the view into pixels. **Hardware mode (default):** `Surface.lockHardwareCanvas()`
   on an `ImageReader` surface, then the frame is read into a `byte[]`. **Software mode:** `View.draw()` on a `Bitmap`.
3. Godot receives `surface_frame`, asks for the bytes (`readSurfaceFrame`) and calls `ImageTexture.update()`.
4. Page -> Godot events use the existing message path with a surface id; Godot -> page uses `evaluateJavascript`.
5. `tap(x, y)` injects a synthetic `MotionEvent` down/up at that page pixel.

No browser engine is added: it is the same system WebView as the overlay.

## Measured on a device (one phone: Mali-G57, 2408x1080, Godot 4.7.2 mobile renderer)

One 640x400 surface at 10 Hz, game at 58-61 FPS with or without it (no measurable change):

| | Hardware (default) | Software |
|---|---|---|
| Page draw, on the Android UI thread | about 1.8-2.5 ms (4-11 ms while the page warms up) | about 19-21 ms |
| Copy into Godot | about 0.55 ms per frame | about 0.45 ms |
| Page change to texture ready | about 12-17 ms (+ up to one 100 ms frame interval) | about 19-21 ms |

Four surfaces drawn at once (hardware, 10 Hz each, about 9 frames per second each): the game ran at 52-59 FPS with one
dip to 32 FPS right after the app resumed from the background. Freeing two and creating one again worked; a surface beyond
`active_distance` stopped drawing (its frame count stayed put) and stayed stopped after pausing and resuming the app. With `pause_when_offscreen` a screen behind the player drew 0 frames while the one in front drew about 10 per second, and they swapped when the camera turned around.
Software mode costs a 20 ms stall of the UI thread per frame, which can delay overlay touch handling: use it only if
hardware mode misbehaves on a device (`GodotWebUI.surface_capture_mode`).

## Limits and unresolved issues

- **One device.** All Android numbers are from a single phone. Other GPUs, Android and WebView versions are untested; the
  hardware path depends on `ImageReader` and `lockHardwareCanvas` behaving. The 8-surface limit and four simultaneous
  surfaces were tried once; eight at once was not.
- **Taps only.** No drag, scroll, hover, multi-touch, text entry or keyboard on a surface.
- **Low redraw rate** (10 Hz by default): CSS animations look like low-frame-rate video; not for fast motion, video or WebGL.
- **Memory** of the extra WebViews was not measured.
- Not verified: orientation changes with surfaces alive, very large pages, devices where
  the hardware canvas fails, the desktop preview on macOS and Linux (Windows 11 with godot_wry 0.2.0 only).
- The frame transfer is a copy (zero-copy through `ExternalTexture` was not attempted: the copy costs about 0.55 ms).
- A surface needs the overlay started first (it shares the UI folder and bridge), and only one overlay can run at a time.
- `logcat` shows harmless `gralloc4: Format allocation info not found` lines when the `ImageReader` is created on this device.
- Android only; no iOS. The desktop preview is not a runtime platform.

## Alternatives that were considered

- **Native `SubViewport` UI in Godot** with the HTML overlay as a "focus mode" for complex screens: the fallback if a device
  cannot draw surfaces; no native code, but the HTML pages cannot be reused.
- **CEF / GeckoView / an embedded engine:** rejected, tens of megabytes of dependency.
