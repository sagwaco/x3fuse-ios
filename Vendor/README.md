# Vendored sources

## x3f-render

Temporary snapshot. Remove it when x3f-render is published as a shared package
with RENDER_VERSION 20 or later.

- Source: https://github.com/sagwaco/x3fuse, path `src-tauri/crates/x3f-render`
- Commit: `737688ff255c0b0e735fa374ff764ebb89517818`
  (2026-10-27, "fix(export): enable DNG highlight recovery for Quattro")
- Modifications: optional logical source dimensions in `RenderOptions`, geometry,
  and grain coordinates for reduced DNG previews, with geometry regression tests.
  Port this patch when replacing the snapshot. Originally extracted with
  `git archive 737688ff255c0b0e735fa374ff764ebb89517818 src-tauri/crates/x3f-render`.
- Why vendored: the public `multiplat` tip (`2c1ba76941ddbc34ca50a09574d9bac769722b56`)
  has RENDER_VERSION 19. The app needs the calibration and renderer at version 20.
- License: GPL-3.0-only, with spektrafilm data under CC BY-SA 4.0. See
  `x3f-render/NOTICE` and `x3f-render/licenses/`. An app that links the
  engine is GPL-3.0-only as a whole.
