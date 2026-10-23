# WebUIScreen: see your HTML screen in the Godot scene editor

A scene that shows an HTML page looks empty in Godot's 2D editor, and the only way to learn which page belongs to it is to read the scripts. `WebUIScreen` is an **editor-only node** that fixes both: it names the page the scene shows and draws a picture of that page in the 2D viewport, at the size of your project's game viewport.

It is optional. Projects that never add the node are not affected, and at runtime the node does nothing (see [What it does at runtime](#what-it-does-at-runtime)).

> **The preview is a picture, not the Android rendering.** It is made by a desktop Chromium (WebView2 on Windows), from the page's current DOM, with your sample state. Use it to see what a screen is and to place it, and check the real look on a device. Limits are listed [below](#what-the-picture-leaves-out).

## Use it

1. Open a scene and add a **WebUIScreen** node as a child of the scene root (*Add Node*, search "WebUIScreen"). It sizes itself to the game viewport (a Control parent: it fills it; any other parent such as a Node2D root: the project's viewport size) and is locked in the 2D view so it does not swallow clicks meant for the nodes behind it. Put it first in the tree if you want it drawn behind your other nodes.
2. In the Inspector, set **Page** to your `.html` file (the file picker, or drag the file from the FileSystem dock onto the field).
3. Press **Refresh Preview** in the block at the top of the Inspector. A separate program renders the page (about three seconds); the picture appears in the 2D viewport. Nothing from your game starts.
4. Press **Edit UI** to open the page in the WebUI dock's visual editor, with the page already selected and the preview started.
5. When files of the page change, the Inspector says the preview is out of date (and the node's tag in the viewport turns orange). Press **Refresh Preview** again. Nothing is captured automatically.

Properties: **Page** (the `.html` file), **Manual Preview** (optional PNG to show instead of the generated one: a screenshot of your own, or a fallback on a machine where the capture cannot run), **Show Preview** (draw it in the editor), **Show Backdrop** (draw the project's background color behind the picture; off by default so the scene shows through transparent areas).

Scripts can read which page a scene shows instead of repeating a path:

```gdscript
@onready var screen: WebUIScreen = $WebUIScreen
func _ready() -> void:
    ui.start(screen.get_ui_dir(), screen.get_page_file())   # e.g. start("res://ui", "menu.html")
```

That is optional: the node does not need to be used by code to do its job.

## What the status messages mean

| Message | Meaning |
|---|---|
| No page assigned. / File not found: … / … is not an HTML file | The path is empty, missing (also after renaming or deleting the file: Godot does not update plain file paths), not `.html`, or not a `res://` path. No picture is shown, and the node says so in the viewport, the Inspector and the scene tree's warning icon. |
| No preview yet | A page is set but nothing has been captured. |
| Capturing the preview… | The capture program is running (it is stopped after 45 s). |
| Preview is up to date (1280 x 720) | The picture matches the files as they are. |
| The page changed since this preview was made | Some file in the page's folder (HTML, CSS, JS, JSON, images, fonts, the sample state) has another size or modified time than when the picture was made. |
| Capture failed: … | The reason follows: for example `godot_wry` is missing (`python tools/setup.py wry`), the page could not be opened, or the page could not be drawn. The previous picture is not shown as if it were current. |
| Not shown exactly: … | Things the picture leaves out for this page (see below). |

## How it works

Godot's web view cannot run inside the editor (the editor creates the godot_wry class only as a placeholder), and godot_wry has no screenshot function, so the picture is made by a **separate Godot process** (`webui_preview_capture.tscn`), started when you press Refresh Preview, off screen:

1. It opens the page with the desktop preview backend, with the page's sample state (`.webui-edit/<page>.json`, see [desktop-preview.md](desktop-preview.md)) given to it as `set_state` / `emit_event` would. `web/capture.js` is injected into the **preview copy** of the page; neither your HTML files nor the Android runtime are touched.
2. After a short settling time, `capture.js` copies the page's DOM as it is, embeds every stylesheet, image and font as data URLs, renders the copy as an SVG `<foreignObject>` onto a canvas the size of the project viewport and sends the PNG back in chunks over the normal bridge.
3. The program writes `res://.godot/webui_previews/<page>-<hash>.png` and a `.json` file with the fingerprint of the page's files, then exits. The `.godot` folder is the editor's own cache: it is not exported and is normally git-ignored. The editor loads the PNG into an `ImageTexture`.

The picture size follows `display/window/size/viewport_width` and `viewport_height`, not a fixed phone size.

I also tried an exact screen grab of a visible preview window (it works on this machine, about 0.5 s). It is **not** included: it needs a window that is visible on screen and unobscured, it flashes a window on every refresh, and it needs screen-recording permission on macOS and does not work on Wayland. The in-page capture works with the window off screen and is the one used.

## What the picture leaves out

| Content | What happens |
|---|---|
| `<canvas>` | Copied as the pixels it shows at that moment. |
| Animations, transitions | Shown in their resting state (the note says how many were running). |
| `<video>` | A frame if one is decoded, otherwise left out. |
| `<iframe>`, `<embed>`, `<object>`, `<audio>` | Left out. |
| Images, fonts, `url(...)` assets | Embedded from the UI folder. One that fails to load or is over 8 MB (48 MB in total) is left out and listed. `@import` rules and SVG `<use>` of another file are not followed. |
| JavaScript-driven state | Only what the sample state sets up. Without a sample file a page shows its placeholders. |
| Scroll position, hover, focus, `:active` | Not reproduced. |
| Rendering differences | Desktop Chromium, not the Android System WebView: fonts available on this machine, anti-aliasing, and some effects can differ. `backdrop-filter` cannot blur the game on Android either. |
| Transparent areas | Stay transparent in the editor too: the nodes of your scene behind the picture show through, as they are under the real overlay. Turn on **Show Backdrop** to draw the project's background color behind the picture instead. |

## What it does at runtime

Nothing. In a running game (and when you press Play in the editor) the node hides itself, ignores the mouse, has no children, does not process, and never touches `GodotWebUI`: no WebView is created, no overlay starts, no input is taken. The page is shown by `GodotWebUI.start()` exactly as before. `tests/webui_screen_test.gd` checks this. The node's script is part of exported games and contains no editor-only classes; the Inspector block, the dock hook and the capture program are editor-only code. The preview PNGs live in `.godot` and are never exported.

## Verification status

Verified on one Windows 11 machine with Godot 4.7.2 and godot_wry 0.2.0: the node in a real editor session (sizing under a Node2D root, locking, status messages, Inspector buttons, refresh, stale detection, Edit UI opening the dock, a missing page), real captures of the demo `hud.html` and `menu.html`, and the runtime-inert behaviour in a headless test.

Not verified: macOS and Linux (godot_wry's transparency is unsupported on Linux), HiDPI displays, a very large page, an image- and font-heavy page, dragging an `.html` file from the FileSystem dock onto the Page field (the file picker works; the drop target is Godot's standard file-path field), the exported game with a `WebUIScreen` in a scene (the runtime behaviour was tested headlessly, not in an APK on a device), and how closely the picture matches the Android WebView.
