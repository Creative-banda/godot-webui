# Desktop development preview

Run your game from the Godot editor (F5 / F6) on Windows, macOS or Linux and see and use your HTML UI inside the running game, so you can iterate on HTML/CSS/JS without exporting an APK.

> **This is a development aid, not a supported runtime platform.** Android remains the only supported target. The preview runs only when the project is launched from the Godot editor, and the optional dependency it needs is **not** shipped with this repository and is installed **outside your project**.
>
> **Verification status:** tested on one Windows 11 machine with godot_wry v0.2.0 and Godot 4.7.1 (see [Verification status](#verification-status)). macOS, Linux, keyboard/focus behaviour and a launch from the editor's own F5 button are untested.

## How it works

The preview uses the optional [godot_wry](https://github.com/MingHuiLiu/godot_wry) GDExtension (MIT, built on the `wry` crate). Its `WebView` node creates a native OS webview (WebView2 on Windows, WebKit on macOS, WebKitGTK on Linux/X11) as a child window that covers the game window and is always drawn on top.

`GodotWebUI` picks the backend automatically (`WebUIBackendFactory`): Android uses the native plugin; Windows/macOS/Linux use the preview backend when running from the editor; anything else gets the null backend. Your GDScript and your HTML/JS use the same API in both cases.

- **Loading the extension:** the backend loads godot_wry at run time with `GDExtensionManager.load_extension()` from a folder outside the project. Because it never lives in `res://`, Godot cannot package it into an export. (We checked: an extension that is inside the project gets its Android libraries added to the export by Godot's built-in GDExtension handling, and the export fails when those libraries are missing. An export plugin cannot prevent that.)
- The UI folder is copied to `res://.webui_preview/ui/`, with `godot.js` inlined at the start of every HTML file, and the webview navigates there. (The dependency can neither inject a script before page scripts nor serve files outside `res://`.) The folder starts with a dot, so Godot ignores it, and it is not exported.
- Page → Godot: `window.ipc.postMessage(string)` (`godot.js` adapts to it automatically) → the node's `ipc_message` signal → the same `WebUIBridge` validation as on Android.
- Godot → page: `eval()` of `window.Godot.__receive(name, json)`, the same call Android makes (events use the same `@e:` marker as on Android).
- **Hot reload:** every 0.5 s the backend checks the modification times of the files in your UI folder. When something changes it re-copies the folder and reloads the page; the page sends its ready handshake again, so `page_ready` fires and your code re-sends state. Disable with `GodotWebUI.desktop_preview_hot_reload = false`.

## Setup

**Automatic:** `python tools/setup.py wry` downloads the pinned archive, verifies its SHA-256, installs the files for your OS into the folder below and records them (see [setup.md](setup.md)). Run it again any time to verify or repair. The manual steps that follow are the fallback and show exactly what it does.

Requirements: Godot **4.7+** (the extension declares `compatibility_minimum = 4.7`; 4.7.1 is the version this repository targets).

1. Download `godot_wry.zip` from the [godot_wry releases](https://github.com/MingHuiLiu/godot_wry/releases) (desktop, Android and iOS builds in one archive; each package is rooted at `addons/godot_wry`). It is third-party native code that runs inside the editor and your game process: review the source and pin the release you tested. The v0.2.0 archive tested here was 16,390,777 bytes with SHA-256 `3df4a42f79539caf8b4b9620675cf556cd3f9f42962c696a73559f4a23344c6d`.
2. Create the install folder and copy the **contents of the archive's `addons/godot_wry/` folder** into it. Only the library for your own OS is needed (for example `bin/x86_64-pc-windows-msvc/godot_wry.dll` on Windows), plus `WRY.gdextension`.

   | OS | Folder (`OS.get_data_dir()` + `godot_webui/godot_wry`) |
   |---|---|
   | Windows | `%APPDATA%\godot_webui\godot_wry\` (tested) |
   | macOS | `~/Library/Application Support/godot_webui/godot_wry/` (not tested) |
   | Linux | `~/.local/share/godot_webui/godot_wry/` (not tested) |

   The folder must contain `WRY.gdextension` directly. Alternatively set the environment variable `GODOT_WEBUI_WRY` to the folder (or to the `.gdextension` file) and restart Godot.
3. Run the project with F5 or F6. No restart of the editor and no plugin setting is needed; the extension is loaded when the overlay starts.
4. Linux additionally needs WebKitGTK installed and an X11 session (the extension does not check this). Windows needs the WebView2 runtime (included with current Windows 10/11).

**Do not put godot_wry into your project** (`res://addons/godot_wry`). It works for running, but Android exports then fail or get its libraries packaged, and the export log shows a WebUI error telling you to move it. If a copy already exists in the project, it is used as is (the class is already registered), so you can move it out at any time.

The folder `res://.webui_preview/` is generated at run time and contains a `.gdignore`; it is git-ignored in this repository. Add it to your own `.gitignore`. The project folder must be writable when running from the editor.

## Using it

- Write your UI as usual (see the README). Keep the page background transparent.
- Press F5 / F6, edit your HTML/CSS/JS, save, and the page reloads inside the running game.
- The webview is created with developer tools enabled; right-click → Inspect (or the extension's own shortcut) opens the inspector. Disable with `GodotWebUI.desktop_preview_devtools = false`.
- Console output of the page is visible in the inspector. (Android forwards it to Godot's output; the preview does not.)
- `ui.get_backend_name()` returns `"desktop_preview"` in the preview and `"android"` on a device; `Godot.preview` is `true` in the page during the preview.
- Keyboard: the demo reads key *events* (`_input`), not `Input.is_action_pressed()` polling. When the preview overlay has keyboard focus its key presses reach Godot as injected events, which polling does not see. If your game uses polling for keyboard input, it will not react while the overlay has focus in the preview; use `_input`/`_unhandled_input` (or `Input.parse_input_event`-aware code) for keys you want to work there. This does not apply on Android.
- Use the project's window size (for example 1280×720 landscape) to approximate a phone screen.

## Visual editor (dock) and edit mode

Enable the plugin and open the **WebUI** dock (right side, upper left slot). Pick a page, press **Open preview** (a separate window that stays on top of the editor, so it remains visible while you work in the dock), and click an element in it. The inspector identifies what you selected and shows the sections that suit it:

| Element | Sections (the first ones are open, the rest collapsed) |
|---|---|
| Text (`p`, `span`, headings, `label`, text-only `div`...) | Content (text), Typography, Spacing, then Size, Background, Border, Effects, Layout |
| Container (`div`, `section`, `main`...) | Layout (flex or grid controls only when it is one), Size, Spacing, Background, Border, then Effects, Typography |
| Button, link, form control | Content (text, title, placeholder, value, href), Colors, Typography, Size, Spacing, Border, Interaction (cursor, pointer events, selection), then Background, Effects, Layout |
| Image, media | Content (source read-only, alt, title), Size (incl. aspect ratio), Image (object-fit/position), Spacing, Border, Effects |
| SVG | Appearance (fill, stroke, stroke width, color, opacity), Size, then Spacing, Effects, Layout |
| Child of a flex or grid container | an extra Flex item / Grid item section (grow, shrink, basis, align-self, order / column, row) |

Positioned elements also show top/right/bottom/left. Margin and padding are one row of four fields (top, right, bottom, left); arrow keys step numbers (Shift x10, Alt x0.1); bare numbers get `px`.

**Where a value comes from.** Each row knows whether its value is set by a rule (and which: selector, file, `@media` condition), set by a shorthand (`padding: 4px 8px` sets `padding-top`; `font: inherit` sets the font size), uses a variable (`var(--mint)` is shown as written and the variable named), inherited from an ancestor, or a browser default. Rows that cannot be edited say why (the style attribute in the HTML, a rule in a `<style>` block).

**Where a change goes.** Automatic mode writes to the narrowest rule that can take it: the rule that sets the value now if it belongs to this element alone; otherwise another rule that matches only this element; otherwise a new `#id` rule at the end of the stylesheet (needs a unique id); only when none of that is possible does it write to a shared rule, and then it says how many elements that affects. **Apply to** lets you choose a rule or "this element only" yourself. If another declaration has higher priority (`!important`, a more specific selector, the style attribute, an animation), the page detects that the change has no effect, undoes it, and the next candidate is tried; if none works, the dock says what overrides it instead of saving something ineffective. A declaration that has to beat an `!important` one is written `!important`.

**Saving.** **Save** edits the files in place: one value changes or one declaration/rule is added, comments and formatting stay, and nothing is written if the file changed since the page loaded. Text and attribute edits (`alt`, `title`, `placeholder`, `value`) patch the page's HTML only when the target is certain: the text must appear exactly once in the file as plain element text, and attributes need a unique `id`. The text of an element inside the selected one (the `<b>Play</b>` of a button) appears as its own "Text in <b>" row; text that JavaScript fills in at run time is refused. **Undo** takes changes back one at a time; after a save it restores the files as they were before it. Turn **Select** off to use the page normally (for example to reach another screen of the menu), then on again. The preview needs godot_wry (see Setup); problems starting it appear in the dock's status line.

**Sample state.** The preview has no game behind it, so a HUD shows its placeholders ("waiting for Godot...", `--`). Open the **Sample state** block in the dock and describe what Godot would send:

```json
{
  "states": { "hud": { "coins": 12, "dummy_hp": 60, "dummy_max": 100 } },
  "events": [ { "name": "toast", "payload": { "text": "Dummy defeated!" } } ]
}
```

**Apply** checks the JSON, shows it in the preview (as `set_state` / `emit_event` would, and again whenever the page reloads) and saves it next to the page as `.webui-edit/<page>.json`. **From the page** fills in the state and event names the page's scripts listen for (`Godot.on`, `Godot.onState`, `Godot.onEvent`) with empty values. The hidden `.webui-edit` folder has a `.gdignore` and is skipped by the export plugin, so it is never packaged; commit it if you want the sample to travel with the project. Removing the text and pressing Apply deletes the sample; values already shown stay until the page reloads.

How it fits together:
- `addons/webui/webui_edit_preview.tscn` runs the page in this preview with `web/edit_mode.js` injected after `godot.js` (`GodotWebUI.desktop_preview_inject_scripts`; empty by default, ignored on Android, never part of an export). The edit script swallows clicks, reports the selected element (kind, attributes, text, computed style, matching rules with their file, path, specificity and how many elements each affects, inherited sources) and applies each change live, verifying that the element's computed value really becomes what the new value gives.
- `WebUICssCatalog` is the single list of editable properties (how each is edited, which declarations count as setting it, which sections suit which element). `WebUIEditorModel` holds the logic (resolution, choice of rule, unsaved changes, undo, replay after a reload); `WebUICssPatcher` and `WebUIHtmlPatcher` write the files.
- `WebUIEditLink` (editor) starts the preview as its own program in a normal window (an editor-played game can be embedded in the editor, where it cannot stay on top) and talks to it over a local TCP connection (127.0.0.1 only); the dock tells the preview which page to open through `user://webui_edit_target.json`.
- Hot reload stays on, so files edited elsewhere (an editor, an AI agent) reload the page and the dock re-applies unsaved changes; the dock pauses it around its own saves so saving does not reload the page.

Limits: only external `.css` files are edited (rules from `<style>` blocks or `style=""` attributes are listed but read-only); nested CSS, `@container`, and values containing `;` or backslashes (including `url(data:...;base64,...)`) are refused; a rule inside `@media` is only written to when it is what currently sets the value, and then applies only at that size; a variable (`var(--x)`) is replaced by the literal value you type (the variable itself is not edited yet); a property set by JavaScript or an animation is refused or has no effect; text is edited only for plain single-text elements; the preview window is not phone-sized and has no safe-area insets; undo after a save goes back one save only. Tests: `tests/css_catalog_test.gd`, `html_patcher_test.gd`, `editor_model_test.gd`, `editor_dock_test.gd`, `edit_link_test.gd` (headless) and `edit_preview_test.gd` (needs a window).

The **WebUIScreen** node uses the same preview backend to make the picture of a page that it shows in the 2D scene editor: see [webui-screen.md](webui-screen.md).

## Differences from Android (read before trusting what you see)

| Area | Android | Desktop preview |
|---|---|---|
| Engine | Android System WebView (Chromium) | WebView2 (Chromium) on Windows; WebKit on macOS; WebKitGTK on Linux. Rendering/CSS can differ from Android |
| Input | Touch, multi-touch, pointer events from fingers | Mouse and keyboard only; **multi-touch and joystick-plus-button-at-once cannot be tested** |
| Touch modes (`AUTO`/`MODAL`/`REGIONS`) | `AUTO` starts modal and passes touches outside the marked elements to the game after `Godot.touchRegions()` | **Not emulated.** The webview takes mouse input over the whole window; the extension also forwards mouse and keyboard events to the game, so a click on a HUD button may reach the game as well. `set_touch_mode()` is accepted and ignored |
| Keyboard focus | Not applicable | The webview may take keyboard focus; the extension forwards key events to the game while the page has focus |
| Transparency | Supported (verified on one device) | Verified on one Windows machine; **unverified on macOS; not supported on Linux** |
| Lifecycle | Pause/resume, `suspended`, renderer-death recovery | None |
| Security | Network and navigation blocked, CSP, origin-restricted bridge | Not equivalent: external requests are not blocked. A page that works here can still be blocked on Android |
| Safe-area insets, density, performance | Real device | Not representative |
| UI scale (`ui_reference_size`) | `WebView.setInitialScale` re-lays the page out; live on size and density changes | Page zoom (`WebView.zoom`) chosen from the window size and OS scale; the page first loads at 1x and is zoomed about 100 ms later. The user's zoom hotkeys are disabled |
| Console forwarding | `console_message` signal and Godot output | Inspector only |
| Window | Full screen | Covers the whole game window; the Godot window cannot be clicked directly beneath it |

Always test on a device before shipping.

## Diagnostics

Problems are reported through the `error` signal (and `push_warning`) with these codes:

| Code | Meaning and fix |
|---|---|
| `desktop_preview_missing_dependency` | godot_wry was not found. The message lists the folders searched; install it there (see Setup). |
| `desktop_preview_load_failed` | Godot found `WRY.gdextension` but could not load it (needs Godot 4.7+ and the library for this OS beside it). |
| `desktop_preview_needs_restart` | Godot asks for an editor restart before the extension can load. |
| `desktop_preview_incompatible` | The extension loaded but no instantiable `WebView` `Control` class appeared; it is not godot_wry. |
| `desktop_preview_no_host` | `start()` was called before the `GodotWebUI` node was in the scene tree. |
| `stage_failed` | The preview copy under `res://.webui_preview/` could not be written or a UI file could not be read. |
| `bad_ui_dir`, `bad_path` | The UI folder or page path is invalid. |
| `message_too_large` | A page message exceeded 64 KB. |
| `unsupported_platform` | Running a desktop build outside the editor, or an unsupported OS. Only Android is supported at runtime. |

`start()` returns `false` in all failure cases; the game keeps running without a UI.

## Verification status

Tested with godot_wry v0.2.0 (`godot_wry.zip`, SHA-256 above), Godot 4.7.1, Windows 11, an NVIDIA GT 730 (Vulkan). The game was launched with the Godot 4.7.1 editor binary (`godot --path <project>`), which carries the same `editor` feature flag as a run started from the editor, in an isolated copy of this project.

**Verified**
- The extension loads in Godot 4.7.1, both when placed in `res://addons/godot_wry` and when loaded at run time from a folder outside the project with `GDExtensionManager.load_extension()` (the design above), and the factory selects the preview backend.
- The webview is created and the page's ready handshake arrives (about 0.4-0.6 s after `start()` in these runs).
- `window.Godot` exists before page scripts, `Godot.preview` is `true`, and `window.ipc` works: a page-to-Godot message arrived and a Godot-to-page `eval` ran.
- Relative CSS/JS in the staged folder load, and the document background is transparent.
- **Transparency on Windows:** a screenshot shows Godot-drawn shapes through the translucent HTML menu, and the HUD over the running game scene.
- Menu to game navigation (`menu_play` reached Godot and the HUD page loaded and sent its ready handshake). In that run the click on Play was not driven by the test script, so it was most likely a manual click; treat real mouse input as probable, not independently confirmed.
- **Hot reload:** editing a UI file triggered a re-copy and reload; the page was ready again about 0.6 s after the edit.
- **Export isolation:** a real Android export of a project without godot_wry in it succeeds and contains no godot_wry files; with godot_wry inside the project the export fails (non-Gradle) or packages its library (Gradle), which is why the install location is outside the project.
- The backend logic, error codes and staging are also covered by `tests/headless_test.gd` against a stand-in node.

**Not verified**
- macOS and Linux, including the data-folder locations above; Linux transparency is documented as unsupported by the extension.
- Keyboard focus and key forwarding to the game, and which events reach the game when clicking page controls (documented by the extension, not observed).
- Launching with the editor's own F5/F6 buttons and the 4.7 embedded Game workspace.
- Behaviour on exported desktop builds (not a goal; the preview is editor-only).
- Android behaviour after the backend seam change (not re-tested on a device).

**Observed quirks**
- The staged page's origin appears as `http://res..webui_preview/...` (the extension maps `res://` paths to `http://res.<path>` and the stage folder starts with a dot). Loading worked, but it is an unusual host name.
- The extension prints its own `[Godot WRY] create_webview ...` lines.
