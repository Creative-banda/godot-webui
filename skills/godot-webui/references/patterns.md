# Patterns (every call below exists in addon 0.1.0)

Check the installed `webui.gd` / `godot.js` before reusing; the repository's `examples/minimal_hud/` is the small complete version of the first three patterns and has headless tests.

## 1. Button triggers a gameplay action

```html
<button id="attack" data-webui-touch>Attack</button>
<script>
  Godot.touchRegions();   // pass-through for everything outside [data-webui-touch]
  document.getElementById('attack')
    .addEventListener('click', () => Godot.emit('attack', { heavy: false }));
</script>
```

```gdscript
func _ready() -> void:
    add_child(ui)
    ui.on("attack", _on_attack)
    ui.start("res://ui")

func _on_attack(payload: Dictionary) -> void:
    var heavy: Variant = payload.get("heavy", false)
    if typeof(heavy) != TYPE_BOOL:          # never trust the page
        return
    player.attack(heavy)                    # Godot decides what happens
```

Use `click` for discrete buttons; use Pointer Events for held controls (pattern 5).

## 2. Game state updates the interface

```gdscript
func _ready() -> void:
    ui.page_ready.connect(_push_state)      # first load, reloads, hot reload, recovery
    player.health_changed.connect(_push_state)

func _push_state() -> void:
    ui.set_state("hud", {"health": player.health, "max_health": player.max_health})
```

```js
Godot.onState('hud', (s) => {
  bar.style.width = (s.health / s.max_health * 100) + '%';
  label.textContent = s.health + ' / ' + s.max_health;
});
```

Send the whole state object each time (the newest per name wins), and keep one state name per concern (`hud`, `settings`, `stats`). Avoid sending identical state every frame; compare with the last sent value first (the demo's `game.gd` does this).

## 3. One-shot events

```gdscript
ui.emit_event("hit", {"damage": 12, "crit": true})
```

```js
Godot.onEvent('hit', (e) => spawnFloatingNumber(e.damage, e.crit));
```

Events are for things that happen once. Do not use them for values the page must be able to show later (use state), and do not rely on a freshly loaded page seeing events from before it subscribed.

## 4. Several pages

```gdscript
# menu -> game: Godot swaps its scene and points the overlay at the HUD page
ui.clear_handlers()                       # drop the menu's handlers
ui.load_page("hud.html")
ui.on("jump", _on_jump)                   # then register the HUD's
ui.page_ready.connect(_push_hud_state)    # connect once; do not connect it again per page
```

`load_page` resets readiness and drops held state/events for the old page, so push state in `page_ready`. See `examples/playable_character/app.gd` (`show_page`) for a complete shell that owns one overlay across scene changes.

## 5. Held input (joystick or hold button) without stuck input

```js
let pointer = null;
const release = () => {
  if (pointer === null) return;
  pointer = null;
  Godot.emit('attack_released');
};
btn.addEventListener('pointerdown', (e) => {
  if (pointer !== null) return;
  pointer = e.pointerId;
  btn.setPointerCapture(e.pointerId);
  Godot.emit('attack_pressed');
});
for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) {
  btn.addEventListener(type, (e) => { if (e.pointerId === pointer) release(); });
}
Godot.guard(release);          // blur, page hide, app pause
```

Track one `pointerId` per control so several controls work at once. On the Godot side also clear held input on `ui.suspended`. Throttle continuous values (the demo joystick rounds to 2 decimals and sends only on change). The demo's `ui/hud.js` implements a joystick this way.

## 6. Reading the desktop preview vs Android

```js
if (Godot.preview) { /* desktop development preview: mouse only, not Android */ }
```

Use it for developer-only hints, never to change gameplay behavior.

## 7. Settings owned by Godot, edited by the page

```js
slider.addEventListener('input', () => Godot.emit('settings_changed', { music: Number(slider.value) }));
Godot.onState('settings', (s) => { slider.value = s.music; });   // redraw from Godot's reply
```

```gdscript
func _on_settings_changed(p: Dictionary) -> void:
    if typeof(p.get("music")) in [TYPE_FLOAT, TYPE_INT]:
        settings.music = clampf(p.music, 0.0, 1.0)     # validate and clamp
    ui.set_state("settings", settings)                  # echo the truth back
```

## 8. Error handling

```gdscript
ui.error.connect(func(code: String, text: String) -> void:
    printerr("WebUI ", code, ": ", text))
if not ui.start("res://ui"):
    pass   # the reason was already emitted through `error`; the game keeps running without the overlay
```

## Anti-patterns

- Putting gameplay rules, cooldowns or inventory truth in JavaScript.
- Using `localStorage`, `sessionStorage`, `eval`, popups, external URLs or web fonts (blocked or unavailable on Android).
- Assuming `Godot.on` replays events (it replays state only), or that a page survives a reload with its variables.
- Calling `ui.set_state` / `emit_event` before `start()` and expecting delivery without a successful start.
- Sending an array or a string as a payload; payloads are objects.
- Registering `page_ready` handlers repeatedly (one connection per screen change leaks handlers).
