# WebUIScreen: show an HTML screen in the Godot scene editor

`WebUIScreen` is an optional, editor-only node. A scene that shows an HTML page looks empty in the 2D editor and gives no hint which page it uses; this node names the page and draws a picture of it at the project's game viewport size. Full user documentation: `docs/webui-screen.md` in the addon repository.

## When to add one

When you create or change a scene that is shown together with a WebUI page (a menu scene, a HUD scene, a pause screen), add a `WebUIScreen` child to the scene root and set its `page`, unless the user does not want it. Tell the user to press **Refresh Preview** in the Inspector (you cannot make the picture yourself: it needs the editor and the optional godot_wry dependency). Do not add it to scenes that show no page.

Use *Add Node* in the editor (search "WebUIScreen"). Writing it into a `.tscn` by hand needs the script reference, because a node of a script class is saved as its base type plus a script:

```
[ext_resource type="Script" path="res://addons/webui/webui_screen.gd" id="3_screen"]
...
[node name="WebUIScreen" type="Control" parent="."]
script = ExtResource("3_screen")
page = "res://ui/menu.html"
```

The node takes the size of the game viewport on its own when it is first added in the editor.

## API (the only members; do not invent others)

| Member | Meaning |
|---|---|
| `page: String` (`@export_file("*.html")`) | The page this scene shows (a `res://` file). |
| `manual_preview: String` (`@export_file("*.png")`) | Optional PNG shown instead of the generated preview. |
| `show_preview: bool` | Draw the preview in the editor (never drawn at runtime). |
| `show_backdrop: bool` | Draw the project's background color behind the picture (default off: transparent areas show the scene's nodes). |
| `get_ui_dir() -> String` | The UI folder that holds the page, e.g. `res://ui`: the first argument of `GodotWebUI.start()`. |
| `get_page_file() -> String` | The page's file name inside that folder, e.g. `menu.html`: the second argument. |
| `get_status() -> Dictionary` | `{state, text, notes}` for the editor; states `no_page`, `invalid`, `no_preview`, `capturing`, `fresh`, `stale`, `failed`, `manual`. |
| `refresh_preview() -> bool` | Starts a capture. Editor only (returns `false` at runtime). |
| signal `status_changed` | The status changed. |

Using `get_ui_dir()` / `get_page_file()` instead of repeating a path string is optional but useful: the scene then states which page it shows. Existing `GodotWebUI` calls and the Android runtime stay exactly as they are.

## Rules

- It must never replace `GodotWebUI.start()`: the node does not render, create a WebView, take input or show anything at runtime (it hides itself). Do not add game logic or signals to it, and do not parent other nodes under it.
- The preview is a **picture, not the Android rendering**. Never describe it as what the player will see. It is made by desktop Chromium from the live DOM with the page's sample state (`.webui-edit/<page>.json`), so give every page that shows Godot values a sample state (SKILL.md section 4, rule 8) or the picture shows placeholders.
- What it leaves out, say so when it matters: videos without a decoded frame, iframes, scroll/hover/focus states, animations (shown at rest), assets that fail to load or are over 8 MB, `@import` rules, fonts the desktop does not have. The Inspector lists what a capture left out.
- Pages written the editor-friendly way (SKILL.md section 4) capture best: local images and fonts, `url()` assets inside the UI folder, a canvas is fine (copied as pixels).
- Never read or write `res://.godot/webui_previews/` from game code: it is the editor's cache.

## Messages you may meet and what to tell the user

| Message | Fix |
|---|---|
| File not found / not an HTML file / not a res:// path | Pick the page again; renaming a file in the FileSystem dock does not update the node's path. |
| Capture failed: the desktop preview dependency (godot_wry) is not available | `python tools/setup.py wry` (optional dependency, installed outside the project), then Refresh Preview. |
| The page changed since this preview was made | Press Refresh Preview. |
| Capture failed: … could not be drawn / timed out | The page may be very large or broken; the message names the cause. A **Manual Preview** PNG can stand in. |

The preview needs the desktop preview dependency and was verified on one Windows machine only; macOS and Linux are unverified.
