# The WebUI visual editor: what it edits and how to write pages for it

The addon includes an editor-only tool: the **WebUI** dock in the Godot editor. The user picks a page, presses **Open preview** (the page opens in a separate always-on-top window with edit mode on), clicks an element, and the dock shows the properties that suit that element. Changes show in the preview at once; **Save** patches the source files in place. It is meant for the user's everyday design tweaks (colors, sizes, spacing, text, alignment) without asking an AI. You make that possible by writing pages the way this file describes.

It is a development aid for the desktop preview: it never runs on Android and is never part of an export. Read `docs/desktop-preview.md` in the addon repository for the full description; this file is what an agent needs.

## What it can do

For the selected element it works out the **kind** (text, container, button, link, form control, image/media, SVG) and shows matching sections:

| Kind | Sections |
|---|---|
| Text (`p`, `span`, headings, `label`, text-only elements) | Content (text), Typography (font, size, weight, style, line height, letter spacing, alignment, decoration, case, wrapping), Spacing, Size, Background, Border, Effects, Layout |
| Container (`div`, `section`...) | Layout (display, flex or grid controls only if it is one, position, overflow), Size, Spacing, Background, Border, Effects, Typography |
| Button / link / form control | Content, Colors, Typography, Size, Spacing, Border, Interaction (cursor, pointer events, selection), Background, Effects, Layout |
| Image / media | Content (source read-only, alt, title), Size, Image (object-fit, position, aspect ratio), Spacing, Border, Effects |
| SVG | fill, stroke, stroke width, color, opacity, size |
| Child of a flex/grid container | an extra Flex item / Grid item section |

For every property it knows where the value comes from (a rule with its selector, file and `@media` condition; a shorthand such as `padding: 4px 8px`; a `var(--x)`; inheritance; the browser default), and a change goes to the narrowest rule that can take it. The page verifies every change really takes effect; if something with higher priority overrides it, the change is refused and the dock names what overrides it.

Text and attributes are edited in the HTML file only when the target is certain (see rule 5 below).

## The authoring rules, with reasons and examples

### 1. CSS in external `.css` files, not `<style>` blocks or `style=""` attributes

The editor edits stylesheet files. Rules that live in a `<style>` block or in a `style` attribute are shown as read-only ("controlled by an inline style"), so the user cannot tweak them.

```html
<!-- good -->
<link rel="stylesheet" href="hud.css">
<div id="vitals" class="panel">...</div>

<!-- bad: not editable -->
<style> .panel { background: #123; } </style>
<div class="panel" style="padding: 12px">...</div>
```

Values that genuinely depend on Godot state (a bar's width as a percentage) may be set from JavaScript; everything else belongs in CSS.

### 2. Plain, flat CSS

Supported: ordinary rules with any selector, shorthands, `var(--x)`, `!important`, `@media`, `@supports`, `@layer`, `@keyframes` (not edited). Not supported (refused, never guessed): CSS nesting (`.a { &:hover {} }`), `@container`, and any value containing `;`, `{`, `}`, `/* */` or a backslash (this includes `data:` URLs: reference image and font files instead). A rule inside `@media` is edited only when it is what currently sets the value, so the preview must be showing the size that query applies to (see `responsive.md`).

### 3. Classes for shared looks, a unique `id` for anything the user may tweak alone

If a color is set by a class used on twelve buttons, changing "this button" would change all twelve. With a unique `id` the editor writes `#start { color: ... }` for that element alone. Without one it can only change the shared rule (and says how many elements that affects). Also required for editing `alt`, `title`, `placeholder`, `value`.

### 4. Design tokens as custom properties

```css
:root { --accent: #3ee6a0; --panel: rgba(20, 24, 48, .8); --radius: 16px; }
.panel { background: var(--panel); border-radius: var(--radius); }
```

Editing a property that uses `var(--x)` replaces it with the literal value the user types (the variable itself is not editable yet); keeping tokens in `:root` still makes a theme change a one-place edit in the file.

### 5. Static text in the HTML, once

Text edits patch the HTML file, so the exact text must appear **once** in the file as plain element text (outside comments, `<script>` and `<style>`).

```html
<!-- good: editable -->
<button id="start"><svg>...</svg><b>Start game</b></button>

<!-- not editable: built by script, or the same text several times -->
<script> el.textContent = 'Start game'; </script>
<span>OK</span> ... <span>OK</span>
```

Text of an element inside the selected one (the `<b>` of a button) appears as its own "Text in <b>" row. Text that only exists at run time (health numbers, level names filled from Godot state) cannot be edited in the file: the dock says the script or the sample state puts it there. Its look can still be edited.

### 6. No DOM-generating frameworks

React/Vue/Svelte/Tailwind-runtime pages render a DOM that does not exist in the source files. The editor reads the live DOM, so selection works, but saving cannot map back to the source. Use plain HTML, CSS and a small vanilla script, as the examples do.

### 7. Literal listener names

```js
Godot.onState('hud', render);       // good: the editor can find 'hud'
Godot.onEvent('toast', showToast);  // good
Godot.onState(NAME, render);        // bad: invisible to the template
```

### 8. Sample state next to the page

The preview has no game behind it, so a page that shows Godot values would show placeholders. The dock has a **Sample state** block (JSON) and saves it as `<ui folder>/.webui-edit/<page>.json` next to the page. Create it yourself when you build a page so the user can design with realistic values:

```
ui/
  hud.html
  hud.css
  hud.js
  .webui-edit/
    .gdignore              (empty file: keeps Godot from importing or exporting the folder)
    hud.json
```

```json
{
  "states": { "hud": { "health": 70, "max_health": 100, "level": 1 } },
  "events": [ { "name": "toast", "payload": { "text": "Level 1" } } ]
}
```

Rules: only the keys `states` (name -> object) and `events` (list of `{name, payload?}`); names follow the bridge pattern `^[A-Za-z][A-Za-z0-9_.:-]{0,63}$`; payloads are JSON objects that match what GDScript sends with `set_state` / `emit_event`. Events are re-sent on every page load. The folder is hidden, so the export plugin never packages it; page code must never read it.

## What the user can do with it (so you can tell them)

1. Enable the plugin, open the **WebUI** dock, pick the page, **Open preview** (needs `python tools/setup.py wry` once).
2. Click elements to select them. To reach other screens of a page (tabs, settings panels that are shown by script) untick **Select**, click through the page, then tick it again.
3. Change values; **Apply to** chooses the rule ("this element only" writes a `#id` rule). **Save** writes the files, **Undo** takes changes back one at a time (after a save: the last save).
4. If an AI or an editor changes the files meanwhile, the preview reloads and unsaved changes are re-applied; a file that changed since it was loaded is never overwritten.

## Limits to mention honestly

- Only external `.css` files and the page's own `.html` are edited. `<style>` blocks, `style=""`, script-built text and generated DOMs are read-only.
- The preview runs in WebView2 (Chromium) on desktop, not in the Android WebView, and is not phone-sized or safe-area aware. A design that looks right there still needs a device check.
- Pointer-events-none readouts can be selected, but their script-filled text cannot be edited.
- Specificity ranking is approximate; the page's own check decides, so a refused change names what overrides it.
- The editor was verified on one Windows machine with scripted tests and by hand; nothing about it was tested on a device (it never runs there).
