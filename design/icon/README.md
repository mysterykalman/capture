# Capture App Icon

**Concept:** a net catching a pixel — no camera, aperture, crop-corners,
monitor, screenshot-frame, or cursor imagery, per the spec's explicit
requirements.

- `icon-source.svg` — the 1024×1024 vector master, generated procedurally
  (see below) rather than hand-drawn, so the mesh geometry is mathematically
  consistent (real catenary-style bowed strands converging to one point,
  concentric rings following the same silhouette).
- `preview-1024.png` — a rendered preview at full size, for quick viewing
  without an SVG-capable viewer.

## Design

- Squircle background, blue-to-violet gradient (`#5B7BFF` → `#8557E8`, within
  the spec's suggested palette) with a soft top-left sheen for dimensionality.
- A woven net (7 strands × 5 rings, knotted intersections) drawn as a rounded
  pouch that closes to a point — geometric and refined rather than cartoon
  fishing gear, per the spec.
- One small acid-lime (`#B9E94E`) square "pixel" caught at the point where
  the net closes, with a soft drop shadow and its own subtle radial glow.
- Deliberately **no SVG `<filter>`/`feDropShadow` elements** — an early
  version used them for the net's shadow and the pixel's glow, but they
  triggered a rendering clip bug in Chromium's software (no-GPU) rasterizer
  in this sandbox (the filter region silently clipped ~30% of the icon).
  Shadows are done instead as plain offset/duplicated shapes underneath,
  which is both more portable and (per the spec) already preferred —
  "no glass blur, no gradients on every control."

## Regenerating

`icon-source.svg` was authored via a small generator script
(`/tmp/.../gen_icon.py` in this session's scratchpad — not checked into the
repo since it's a one-off authoring tool, not a build dependency) using
superellipse math for the squircle and catenary-style curves for the net
strands. If the icon needs a redesign, regenerate the SVG procedurally
rather than hand-editing the 200+ generated path points.

## Generating the .icns and asset-catalog PNGs

The PNGs in `../../mac/Resources/Assets.xcassets/AppIcon.appiconset/` in
this repository were rasterized **in this Linux sandbox** using headless
Chromium (`/opt/pw-browsers/chromium`) to render `icon-source.svg` at
1024×1024, then downscaled to every required size with Pillow (Lanczos
resampling) — Chromium's headless screenshot mode produced empty output at
very small window sizes (16×16/32×32), so rendering large-then-downscaling
was the reliable path here. This is a reasonable one-time bootstrap, but on
a real Mac, regenerate from the vector source for the sharpest possible
result at every size, and to produce a proper `.icns`:

```bash
scripts/generate-icons.sh
```

That script uses `qlmanage` (Quick Look's SVG rendering, bundled with
macOS) to rasterize the master PNG, `sips` to produce every required size,
and `iconutil` to build `build/Capture.icns`. It overwrites the PNGs
already committed here with higher-fidelity native-renderer output.
