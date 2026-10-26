# Skybound

A first-person parkour course over the clouds, built to show what a Godot WebUI interface can do on top of a
3D game. About five minutes to learn, a couple of minutes to master: five sections, 25 light shards, three
medals, a spring pad, crumbling and moving platforms, and a Wing Orb that unlocks a double jump.

Skybound is the project's main scene (the primary showcase): press F5, or open `main.tscn` and press F6.

| | Keyboard (desktop preview) | Phone |
|---|---|---|
| Move | WASD / arrows | Stick (push fully to sprint) |
| Sprint | Hold Shift | Push the stick fully |
| Jump | Space (hold for height) | Jump button (hold for height) |
| Look | Drag the mouse | Swipe anywhere else |
| Pause | Esc | Pause button or Android Back |
| Checkpoint | R | Pause menu |

## What the interface shows

Everything on screen except the 3D world is one HTML page (`ui/index.html`, styles in `ui/css/`, scripts in
`ui/js/`), driven by named messages:

- **Screens** switched by Godot (`screen` state): menu, HUD, pause, results, plus settings and how-to-play
  panels. Android Back closes a panel first (`Godot.onBack`), then pauses, resumes or leaves.
- **3D markers**: Godot projects the next checkpoint and the finish beacon to screen fractions each tick and
  the page moves ordinary DOM elements onto them, with distance, clamped to the screen edge when they are
  out of view.
- **Live HUD** at 20 Hz: timer and section, the shard counter first, a wing icon for the double jump (bright
  while available, dim once spent), a quiet fall counter, a crosshair and a small chevron that show only while
  the controller reports sprinting, light speed lines, toasts, a section banner and a 3-2-1 countdown. There is
  no speedometer.
- **Settings and medals** owned by Godot and saved to `user://skybound.cfg`; the page only asks and shows
  the answer. Results count up and reveal the medal.
- **Touch**: virtual stick and jump button, placed in from the sides and up from the bottom where thumbs rest (not in the corners); the jump button (a wing badge shows when the air jump is ready) and a full-screen look
  zone under the controls, so a swipe works while the stick is held. Godot decides whether to show them from the
  real platform (`platform` state: Android/iOS builds yes, desktop no).
- The interface font (Inter, SIL OFL) is bundled in `ui/fonts/` and declared with `@font-face`, so the APK does not depend on what fonts the phone has.
- Animations are transform and opacity only, and the layout scales with `GodotWebUI.ui_reference_size`.

## How it is built

| Part | File |
|---|---|
| Game flow, saves, page messages | `scripts/skybound.gd` |
| First-person body and camera feel | `scripts/sb_player.gd` |
| Course pieces | `scripts/sb_platform.gd`, `sb_moving_platform.gd`, `sb_crumble_platform.gd`, `sb_checkpoint.gd`, `sb_shard.gd`, `sb_wings.gd`, `sb_goal.gd`, `sb_bounce_pad.gd` |
| The course layout | `scripts/sb_level_builder.gd` (a table; tick `rebuild` on the `Level` node to regenerate the saved nodes) |
| Platform look (neon edges, grid) | `platform.gdshader` |
| In-world run terminal: a second page (`ui/terminal.html`) drawn onto a 3D screen with `create_surface` (Android; a label elsewhere). Aim at it and press E / USE | `scripts/sb_terminal.gd`, `scenes/terminal.tscn`; see `docs/world-space.md` |

The scene was assembled with the Godot AI MCP. The course pieces build their meshes at run time, so a platform
is a tiny scene and `size` is the only thing to change in the Inspector.

## Performance on phones

Measured on the Mali-G57 phone at 2408x1080, GPU time per frame (lower is better):

| Change | GPU ms |
|---|---|
| As first built (glow, color grade, full resolution) | about 21 (37-46 FPS) |
| Glow off | 16.8 |
| Glow and color grade off | 15.4 |
| ...and 3D resolution at 75 % | 12.9 |
| **What phones start with now** (effects off, Balanced 75 %) | **12-14 (57-60 FPS)** |

The cost was full-screen passes and fill rate, not geometry: GPU time stayed the same when a view had 3 draw calls
or 89, and 5k or 47k primitives, with about 1 ms of CPU. So culling does not help this scene, and it was tried and
not kept: occlusion culling culled nothing (draw calls stayed at 89) and made the frame slower (+4 ms GPU, +3 ms
CPU); a visibility range halved the draw calls (89 to 42) but left GPU time unchanged. Both would only add
overhead. Desktop keeps the full look (glow and color grade on, 100 %). Both are in Settings (Glow and color grade,
3D resolution) and saved by Godot. Fog and the sky are not the problem; a flat sky saved about 2 ms but changes
the look, so it was left.

## Tests

`godot --headless --path . -s res://tests/skybound_test.gd` checks the scene, the body's physics, the whole
run flow through the same handlers the page uses, and runs a bot that tries every jump of the course
(single jump before the Wing Orb, double jump after). It takes a couple of minutes.

Development arguments after `--`: `--sb-touch` shows the touch controls on desktop, `--sb-autostart` starts a
run, `--sb-run` also runs forward, `--sb-pause` / `--sb-results` stop on those screens.

Not verified on a device: touch feel, frame rate on a phone, Android Back and pause/resume.
