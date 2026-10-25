# Skybound

A first-person parkour course over the clouds, built to show what a Godot WebUI interface can do on top of a
3D game. About five minutes to learn, a couple of minutes to master: five sections, 25 light shards, three
medals, a spring pad, crumbling and moving platforms, and a Wing Orb that unlocks a double jump.

Run `main.tscn` (F6). It is not the project's main scene.

| | Keyboard (desktop preview) | Phone |
|---|---|---|
| Move | WASD / arrows | Stick (push fully to sprint) |
| Sprint | Shift (or auto) | Auto at full push |
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
- **Live HUD** at 20 Hz: timer, section chip, shard and fall counters, a speed gauge, a crosshair that opens
  while sprinting, speed lines above sprint speed, toasts, a section banner, a 3-2-1 countdown and flashes.
- **Settings and medals** owned by Godot and saved to `user://skybound.cfg`; the page only asks and shows
  the answer. Results count up and reveal the medal.
- **Touch**: virtual stick, jump button and a full-screen look zone under the controls, so a swipe works
  while the stick is held.
- Animations are transform and opacity only, and the layout scales with `GodotWebUI.ui_reference_size`.

## How it is built

| Part | File |
|---|---|
| Game flow, saves, page messages | `scripts/skybound.gd` |
| First-person body and camera feel | `scripts/sb_player.gd` |
| Course pieces | `scripts/sb_platform.gd`, `sb_moving_platform.gd`, `sb_crumble_platform.gd`, `sb_checkpoint.gd`, `sb_shard.gd`, `sb_wings.gd`, `sb_goal.gd`, `sb_bounce_pad.gd` |
| The course layout | `scripts/sb_level_builder.gd` (a table; tick `rebuild` on the `Level` node to regenerate the saved nodes) |
| Platform look (neon edges, grid) | `platform.gdshader` |

The scene was assembled with the Godot AI MCP. The course pieces build their meshes at run time, so a platform
is a tiny scene and `size` is the only thing to change in the Inspector.

## Tests

`godot --headless --path . -s res://tests/skybound_test.gd` checks the scene, the body's physics, the whole
run flow through the same handlers the page uses, and runs a bot that tries every jump of the course
(single jump before the Wing Orb, double jump after). It takes a couple of minutes.

Development arguments after `--`: `--sb-touch` shows the touch controls on desktop, `--sb-autostart` starts a
run, `--sb-run` also runs forward, `--sb-pause` / `--sb-results` stop on those screens.

Not verified on a device: touch feel, frame rate on a phone, Android Back and pause/resume.
