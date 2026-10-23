# Animation performance on Android

The WebView is a second renderer running next to Godot on the same phone. Most animation costs nothing; a few CSS patterns repaint a large area every frame and drop a mid-range phone to 10-40 FPS even though the same page is smooth on a PC. No addon setting fixes that, so the page has to avoid those patterns.

## What was measured

One real device: vivo V2312 (MediaTek Dimensity 700, Android 15, 1080x2408 at 60 Hz, Android System WebView 155). A probe page animated 12 translucent panels (or one full-screen element) for 8 s per variant, with Godot idle. FPS is `requestAnimationFrame` cadence in the page. One device, one run per row, so treat small differences as noise and a phone with a stronger GPU as better, not as safe.

| Animated property | FPS | Verdict |
|---|---|---|
| `transform` (translate/rotate/scale), `will-change: transform` | 60 | free |
| `opacity` + `transform` | 60 | free |
| `filter: hue-rotate()` | 60 | fine here |
| 8 full-screen translucent layers fading | 60 | fine here |
| `<canvas>` 40 radial-gradient particles, DPR up to 3 | 60 (1% janky) | fine; DPR 1 is lighter still |
| animated `filter: blur()` | 45 | costly |
| animated `left` / `width` (layout) | 43 | costly |
| animated `filter: drop-shadow()` | 42 | costly |
| moving `background-position` on a wide gradient | 37 | costly |
| animated `box-shadow` | 14 | worst: avoid |
| mixed "rich HUD": box-shadow + filters + particle canvas | 29 | the realistic failure |

With a busy Godot scene behind (400 moving rects), `transform` and `canvas` stayed at 60; `box-shadow` fell to 11, `drop-shadow` to 33 and the mixed page to 25. The cost is the page's own paint work competing for the GPU.

## What does not help (tested, no addon change made)

Hardware or software layer type for the WebView, an opaque background instead of transparent, and raising the renderer priority all stayed inside run-to-run noise on the boxshadow and mixed pages. A transparent overlay is not what makes it slow. The honest summary: there is no switch; the fix is in the CSS.

## Rules for pages

1. Animate `transform` and `opacity` only. Move things with `translate`, grow with `scale`, fade with `opacity`. Do not animate `left/top/width/height/margin`, `box-shadow`, `filter: blur/drop-shadow`, `border-radius`, or `background-position` of a large element.
2. A glow that pulses: put the shadow on a pseudo-element (or a sibling) that is painted once and animate that element's `opacity`/`transform`, instead of animating the shadow itself.
3. Gradients that "flow": animate a larger gradient element with `transform: translate`, not `background-position`.
4. Static `box-shadow`, `border-radius` and gradients are fine; the cost is repainting them every frame.
5. Use `will-change: transform` only on the few elements that really animate continuously. Dozens of promoted layers use GPU memory and can make it worse.
6. Keep animated areas small. A small moving element is cheap; a full-screen one that repaints is not. Avoid stacking large translucent layers that all animate.
7. `<canvas>` effects: cap the device pixel ratio (`Math.min(devicePixelRatio, 1.5)`), keep particle counts low (tens, not hundreds), one `requestAnimationFrame` loop per page, skip the loop when the layer is hidden.
8. Pause what is not visible: set `animation-play-state: paused` or remove infinite animations of screens that are hidden or covered by a modal; stop `requestAnimationFrame` loops while the page is hidden.
9. Decorative loops (ambient glow, shimmer) should respect `@media (prefers-reduced-motion: reduce)` and be easy to switch off from a low-quality setting that Godot owns (`set_state("quality", {...})`).
10. Prefer fewer, bigger motions: one transform-driven transition looks better than many small repainting effects.

## Measuring on a device

Do not claim a page is smooth without a measurement. Two cheap ones:

```bash
adb shell dumpsys gfxinfo <package> reset
# play the animation for 10 s
adb shell dumpsys gfxinfo <package>
```

Read "Janky frames" and the 50th/90th/95th percentile frame times (above 16.7 ms misses a 60 Hz frame). Or log the page's own cadence: collect the gaps between `requestAnimationFrame` callbacks for a few seconds and print p50/p95 with `console.log` (it arrives as the `console_message` signal). Compare against a copy of the page with the suspect animation removed to find the expensive one. The desktop preview is far faster than a phone and says nothing about this.
