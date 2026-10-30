# iPad mini 6 performance checks

Use a bundled Release build on the physical device. Record the app commit, engine
revision, OS version, camera, dimensions, thermal state, and preview size.
Compare the same source files and recipes. Keep original fixtures unchanged.

## Measurements

- Tap to visible control feedback: target p95 below 100 ms.
- Pan and zoom of an existing frame: target 60 frames per second.
- Slider change to displayed preview: measure separately from control feedback.
- RAW preparation, preview render, export, and peak process memory.
- Repeated switching between photos: memory must settle after work completes.
- Export while navigating: controls must remain responsive.

Use Instruments Hangs, Time Profiler, and Metal System Trace for UI and GPU timing.
The automated benchmark measures processing time. It does not measure human taps,
frame presentation latency, or sustained thermal behavior.

## Fixture matrix

Start with one Merrill and one Quattro X3F. Add rotated photos, SD9 without an
embedded JPEG, malformed files, and two imports with the same filename. Use the
same default recipe and exposure adjustment for the desktop reference comparison.
Compare decoded pixels with a declared tolerance; encoded JPEG bytes can differ.

## Lifecycle and storage

Background during preparation and export, then resume. Check cancellation and
saved edits. Interrupt an import and confirm no truncated RAW returns at launch.
Test low storage and conflicting output names. Original files must remain intact.

## Status

Native Release benchmark results on iPad mini 6, iPadOS 26.5.2, renderer 20,
film disabled, preview max edge 1536, one run per fixture:

| Fixture | Import ms | Prepare ms | First render ms | JPEG export ms | Sampled peak MB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Merrill DP2M0643 | 42 | 3065 | 957 | 588 | 804 |
| Quattro DP0Q0010 | 13 | 2886 | 309 | 429 | 980 |

MB uses decimal units. Memory samples were collected every 50 ms; transient peaks
can be higher. First renders include initial GPU setup. These are pipeline wall
times, not UI latency measurements or repeated-run percentile estimates. Both runs
completed full-resolution JPEG exports. Reports are in docs/benchmarks/.

On 2026-10-29, the bundled Tauri Release baseline from feat/ios-poc commit
0796439 was built, development-signed, installed, and launched on the iPad mini 6.
The user reported: "Somewhat better, still too slow" compared with the earlier
development build. This is a subjective baseline. Tap latency and frame timing
have not been instrumented. Editing and export worked in the earlier build.

The Xcode 27 Release build required `rustup component add llvm-tools` before
rebuilding Tauri and its Swift plugins. The native app has no Tauri dependency.

After the native device runs, the user reported that exposure/WB and pinch/pan
were "Responsive enough to continue the native migration" compared with the
Tauri Release baseline. This is subjective device acceptance, not a tap-latency
measurement.

## Stage 2 device acceptance

On 2026-10-29, the signed Release app completed the expanded benchmark on the same
iPad mini 6. Both reports have status `ok` and exact canonical sidecar equality.
Film preview uses Kodak Portra 400 with the full recipe recorded in each report.
The non-film preview and exports use each source's camera defaults.

| Fixture | Prepare ms | Preview ms | JPEG ms | TIFF ms | DNG ms | Film preview ms | Sampled peak MB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Merrill DP2M0643 | 2611 | 207 | 530 | 1945 | 2696 | 445 | 1110 |
| Quattro DP0Q0010 | 2908 | 256 | 399 | 2387 | 3290 | 330 | 1262 |

These are single runs. GPU caches and prior activity differ from the initial runs,
so the table does not establish a speedup. Peaks cover preparation, all three
exports, sidecar exchange, and film rendering. No increased-memory entitlement is
used. UI latency and thermal behavior have not been instrumented.

The exported files were copied back from the iPad and checked with ExifTool.
Both TIFFs contain 16-bit RGB samples, lossless Deflate compression, and the x3f sRGB
profile. Merrill output is 4704 by 3136; Quattro output preserves the source's
panoramic crop at 5424 by 2328. Original DNGs contain 16-bit samples and DNG 1.4
metadata. The Merrill DNG includes its OpcodeList3 gain map; Quattro has no bundled
lens correction and exports the full 5424 by 3616 sensor image.

The user reported that the new light/color controls and film toggle were
"Responsive enough for the next stage". Eleven Release simulator tests passed,
including full recipe preservation, native schema-1 migration, confirmed older
sidecar replacement, film parameter preservation, and conflicting saved edits.
Host engine tests passed with Merrill, Quattro, and a real desktop version-1
sidecar. This does not establish behavior for all camera bodies or X3I fixtures.
Reports are in `docs/benchmarks/stage2-merrill.json` and `stage2-quattro.json`.

## Stage 3 editing controls

The signed Release build completed the expanded device run on 2026-10-29. After
all stage-2 checks, it rendered a crop at x/y 0.1 with width/height 0.8, clockwise
rotation 1, a master curve point at 0.5/0.6, and NLM denoise intensity 6.
`editingRenderMilliseconds` includes normalization, RAW preparation, and rendering.
Both output previews were 1024 by 1536. Each report stores the exact edit recipe.

| Fixture | Combined edit ms | Sampled peak MB |
| --- | ---: | ---: |
| Merrill DP2M0643 | 2459 | 1056 |
| Quattro DP0Q0010 | 2734 | 1263 |

Both reports have status `ok`; JPEG, TIFF, DNG, sidecar equality, and film preview
checks still pass. These are single-run processing measurements. They do not
measure tap latency. BM3D speed, sustained thermal behavior, and all camera models
remain unmeasured on the device. No increased-memory entitlement is used.

Twenty Release simulator unit tests passed. A separate real-image UI smoke test
passed on iPad mini and iPhone 17 simulators with iOS 26.0. It exercised a crop
corner drag, Reset/Cancel, square crop Apply, and curve slider Cancel/Apply. Screenshots
were checked on both layouts. The initial UI test selected the editor's scroll view
behind the curve sheet; the corrected test selects the sheet's scroll view.

Host engine tests passed on Merrill and Quattro: crop and rotation pixel mapping,
curve validation and output, denoise re-preparation, cancellation recovery, and
deterministic restoration of prior settings. The renderer and C ABI did not change
in this stage. Reports are in `docs/benchmarks/stage3-merrill.json` and
`stage3-quattro.json`.
