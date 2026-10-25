# Responsive pages: phones, tablets and any window size

A WebUI page is drawn at whatever size the Android WebView has, and that size varies: small and large phones, notches and cutouts, portrait and landscape, tablets, foldables (which change size when folded), split-screen and freeform windows. During development the desktop preview adds any window size — including maximized windows on 2K and 4K monitors. **Design for a range, not one device**, and keep the interface readable and comfortably sized across that entire range (see the resolution-independence rules in `ui-authoring.md` for the desktop/high-DPI specifics). Android is still the only supported runtime; "wide window" below means large tablets, foldables unfolded, split-screen, the development preview and fullscreen desktop monitors, not a desktop release.

An agent will not do this on its own: left alone it designs for the phone in its head. State it, check it, report it.

## Approach: fluid first, breakpoints second

1. **Base unit from the screen's short side.** Size things in multiples of one custom property so the whole UI scales together, with limits so it never gets tiny or huge:

   ```css
   :root {
     --u: clamp(8px, 1.4vmin, 16px);              /* one "unit": about 8 px on a small phone, 16 px on a large screen */
     --pad: max(var(--u), env(safe-area-inset-left, 0px));
     --touch: max(44px, calc(var(--u) * 5));      /* never below 44 CSS px */
   }
   .hud-button { width: var(--touch); height: var(--touch); }
   .panel { padding: calc(var(--u) * 1.5); border-radius: calc(var(--u) * 2); }
   ```

2. **Text with clamp**, not fixed sizes: `font-size: clamp(14px, 2.2vmin, 22px);`. Keep body text readable at the small end (about 14 px) and stop it growing absurdly at the large end.
3. **Containers fill, content caps.** Menus and dialogs take `width: min(100%, 960px)` (or `min(92vw, 40rem)`), centered, so a tablet or wide window does not stretch a phone layout into long thin rows. HUD pieces stay anchored to the edges instead.
4. **Flex and grid, no fixed heights.** `display: flex; flex-wrap: wrap; gap: var(--u);` and `grid-template-columns: repeat(auto-fit, minmax(160px, 1fr));` adapt by themselves. Avoid `height: 600px`-style values; use `min-height`, `aspect-ratio`, or let content decide. Never position by absolute coordinates measured on one device.
5. **Anchor to edges with safe areas** on every fixed element: `top: max(12px, env(safe-area-inset-top))`, `right: max(12px, env(safe-area-inset-right))`, and so on. The viewport meta must include `viewport-fit=cover` (see the page template in `ui-authoring.md`).
6. **Breakpoints with `@media` only where fluid sizing is not enough.** Use the dimension that matters for a game UI, usually height and orientation, not just width:

   ```css
   @media (max-height: 420px)                      { /* compact landscape phone: tighter spacing, hide secondary info */ }
   @media (orientation: portrait)                  { /* stack the layout, move buttons to the bottom */ }
   @media (min-width: 900px) and (min-height: 560px) { /* tablet / wide window: two columns, larger panels */ }
   @media (min-aspect-ratio: 21/9)                 { /* very wide: keep the HUD in the safe center columns */ }
   ```

   Keep each rule small and in the page's `.css` file (the visual editor edits those; see below).
7. **Do not rely on `100vh` for full height**: use a `position: fixed; inset: 0` container (or `%` of one). Avoid `dvh`/`svh` unless you checked that the target Android System WebView versions support them.
8. **Images and video** use `max-width: 100%; height: auto` or `object-fit`, with `aspect-ratio` set so layout does not jump. Provide images at a resolution that holds on the largest size you support.
9. **Touch first, not hover.** No hover-only controls, no tiny targets, no controls that sit under the thumb zone's reach on a tablet (the corners of a large screen are far from the hands: keep primary actions reachable).

## What to check, and how to report it

Resize the page (the desktop preview window, or the dock's preview) to at least these CSS sizes and look for overlap, clipping, unreadable text, controls under the notch, and stretched layouts:

| Case | Size (CSS px) |
|---|---|
| Small phone, portrait | 360 x 640 |
| Large phone, portrait | 412 x 915 |
| Phone landscape (check the notch side) | 915 x 412 and 640 x 360 |
| Tablet, portrait | 800 x 1280 |
| Tablet, landscape | 1280 x 800 |
| Wide window / unfolded foldable / development window | 1920 x 1080 |
| Desktop fullscreen, QHD | 2560 x 1440 |
| Desktop fullscreen, 4K | 3840 x 2160 |

Only test portrait if the game supports it. In the final report say which sizes you checked and how (preview window, headless screenshots, reading the CSS), that none was a real device, and anything you could not check. Do not claim orientation changes, foldable resizing or safe-area behavior work on a device: they are not verified there.

## Desktop windows, high-resolution displays and device pixel ratio

The desktop preview (and any desktop hosting of the page) can be fullscreen on a 2K or 4K monitor. Three things change there, and none of them is handled by phone-oriented breakpoints alone:

- **The CSS viewport keeps growing.** A 4K monitor at 150 % OS scaling is a ~2560-px CSS viewport; at 100 % it is 3840 px. Anything sized in raw `vw`/`vh` scales with it: a phone-proportioned layout becomes giant, or (authored large) shrinks to unreadable on small phones. Keep type and controls at comfortable CSS-pixel sizes (or double-bounded `clamp()`), and give document-like screens a capped, centered content width so extra space becomes margins and breathing room — see the resolution-independence section in `ui-authoring.md` for the patterns.
- **Device pixel ratio is not your business in CSS.** The browser maps physical pixels to CSS pixels via DPR and OS scaling; do not write `device-pixel-ratio` media queries or fixed physical-pixel sizes, and never assume `1 CSS px = 1 physical px`. Provide raster images at a resolution that holds on the largest supported size.
- **Full-height containers and long lines.** A maximized window makes `100vh` layouts and uncapped text lines unusable: cap content width (~70–90 ch for prose) and use `inset: 0` fixed containers rather than viewport units for height.

At the review stage, confirm the page at a ≥2560-px size: nothing proportionally tiny or huge, content centered and capped, diagrams still legible (labels ≥ ~11 CSS px — scroll or restack a drawing instead of shrinking it), controls still ≥44 CSS px.

## Interaction with the visual editor

- The dock's preview and the `WebUIScreen` picture show **one size at a time** (the project viewport size for the picture). A rule inside `@media` is edited only while that query currently applies, so to adjust a breakpoint, show the page at that size (resize the preview window) or edit the rule in the file.
- Fluid values (`clamp()`, `min()`, `calc()` with `var()`) are shown as written, and replacing one with a fixed number removes its scaling: prefer changing the token in `:root` (for example `--u`) when the user wants the whole UI larger or smaller.
- Keep responsive behavior in the `.css` file and the tokens in `:root`, so the user can still tweak the design without breaking it on other sizes. If a tweak would make a layout fixed-size, say so.

## Review checklist

- No fixed widths/heights that assume one screen; sizes come from `--u`, `clamp()`, `%`, `vmin`, flex or grid.
- Every edge-anchored element uses a safe-area inset.
- Touch targets are at least 44 CSS px at every size.
- Text is readable at the smallest size (about 14 px) and capped at the largest.
- A tablet/wide window does not stretch menus into unreadable rows (content is capped and centered).
- Nothing becomes proportionally tiny or huge between a 360-px phone and a 3840-px fullscreen window: control sizes stay comfortable (CSS-pixel or double-bounded clamp), content is capped and centered on desktop sizes.
- Diagrams and scaled drawings keep labels legible (≥ ~11 CSS px) at every size — `min-width` plus scroll instead of shrinking, capped growth instead of inflating.
- Breakpoints use height and orientation where it matters, and live in the `.css` file.
- The report names the sizes checked (including a ≥2560-px-wide window) and says none was a real device.
