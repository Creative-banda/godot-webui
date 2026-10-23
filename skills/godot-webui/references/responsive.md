# Responsive pages: phones, tablets and any window size

A WebUI page is drawn at whatever size the Android WebView has, and that size varies: small and large phones, notches and cutouts, portrait and landscape, tablets, foldables (which change size when folded), split-screen and freeform windows. During development the desktop preview adds any window size. **Design for a range, not one device.** Android is still the only supported runtime; "wide window" below means large tablets, foldables unfolded, split-screen and the development preview, not a desktop release.

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

Only test portrait if the game supports it. In the final report say which sizes you checked and how (preview window, headless screenshots, reading the CSS), that none was a real device, and anything you could not check. Do not claim orientation changes, foldable resizing or safe-area behavior work on a device: they are not verified there.

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
- Breakpoints use height and orientation where it matters, and live in the `.css` file.
- The report names the sizes checked and says none was a real device.
