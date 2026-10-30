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

## Stage 4 HSL and color grading

Twenty-four Release simulator unit tests passed. The iPad mini and iPhone 17
simulator UI suites passed both the color and crop/curve tests. Color checks cover
wheel drag, draft Cancel, Apply, and saved values after backgrounding and relaunch.
Screenshots were checked on both layouts. The first color UI test compared decimal
strings exactly; the corrected test allows 0.001 for the stored f32 value.

Host engine tests used the Quattro and an as-shot Monochrome Merrill fixture.
They cover recipe ranges, wheel direction, blending/balance output, remembered hue,
sidecar preservation, and deterministic restoration. Monochrome recipes, film, and
RAW channel mixes keep color values but suppress their effect. The native sheets
show a notice and remain editable; desktop hides those controls. Native Reset
grading resets the whole section, including blending and balance. Desktop Reset
wheels resets only the three wheels. The renderer, C ABI, and framework did not
change in this stage.

Three initial Merrill combined runs were cancelled before the new color step.
The diagnostic run completed JPEG, TIFF, DNG, sidecar, and film checks, then received
an iOS memory warning during the denoise change. The user confirmed that the app
stayed unlocked in the foreground. That report records `memoryWarning` and a
sampled peak of 1076 MB. The earlier two reports had no event diagnostic, so their
cancellation causes remain unknown. An initial Quattro combined run passed, with
a 37 ms color step after the denoise change and a sampled peak of 1266 MB.

These results do not establish a fixed process memory threshold or a leak. The
old RAW scene is released before re-preparation. System pressure can still cancel
processing. The app keeps cancellation and session release on memory warnings.
Reports include all three cancelled runs and the initial Quattro run under
`docs/benchmarks/stage4-*`.

The final benchmark measures color immediately after the first preview, before
exports and denoise changes. It uses source-default denoise and sets Standard plus
`monochrome: null` for the Merrill color check only. This is a different workload
from the initial Quattro color measurement. Exact recipes and timings remain in
the reports. A later failure still gives the full run status `error`; a completed
color timing alone does not mean the full run passed.

The final signed Release runs on 2026-10-29 both completed the full benchmark with
status `ok`, exact sidecar equality, and no cancellation events:

| Fixture | Color preview ms | Color preview size | Sampled peak MB, full run |
| --- | ---: | --- | ---: |
| Merrill DP2M0643 | 31 | 1536 by 1024 | 1130 |
| Quattro DP0Q0010 | 41 | 1536 by 659 | 1269 |

Both use source-default denoise 10. Timings include recipe normalization and a
warm preview render, with the RAW already prepared. They do not measure tap latency.
Reports are `stage4-merrill.json` and `stage4-quattro.json`. These successful runs
do not show that system memory pressure is resolved. The earlier failures remain
part of the evidence. The last UI runs preceded only benchmark diagnostics and
measurement-order changes; all 24 unit tests passed again after those changes.


## Stage 5 advanced film

The Release simulator unit suite passed all 26 tests before the final grain-range
fix. Three focused film tests then passed with that fix, including channel values
[0, 1, 100] and [0, 50, 100]. These valid imported values previously could create a
reversed or zero-width slider range. The sheet now handles an immovable base and
keeps the channel controls available. Tests also cover dirty-field preservation,
monochrome inactive channels, native conversion, resets, disabled film, and null
paper exposure. The final signed Release device build passed.

All 16 host engine tests passed with the real Quattro, monochrome Merrill, and
desktop sidecar fixtures. The three new stage-5 tests use 1024-pixel Metal previews
to check exposure, gamma, filtration, couplers, grain, scatter, halation, and
highlight controls. They also check native-over-legacy precedence, the metadata-only
grain base, null versus zero paper exposure, direct-scan print bypass, monochrome
filtration, and nested patch/sidecar preservation. Monochrome couplers affect the
renderer even though both native and desktop UIs hide them. Formatting and clippy
with warnings denied passed. An existing dependency future-compatibility warning
for block 0.1.6 remains. No new export pixel comparison was added.

The signed Release physical runs on 2026-10-29 completed the full benchmark with
status `ok`, exact sidecar equality, and no cancellation events:

| Fixture | Advanced film preview ms | Preview size | Sampled peak MB, full run |
| --- | ---: | --- | ---: |
| Merrill DP2M0643 | 493 | 1536 by 1024 | 1296 |
| Quattro DP0Q0010 | 382 | 1536 by 659 | 1386 |

The advanced step runs after HSL/grading and before exports. It enables native
grain and halation, changes film/print exposure, gamma, filtration, and couplers,
and uses source-default denoise 10. For the Merrill check only, Standard and
`monochrome: null` allow color film processing. Saved photo edits are unchanged.
The timing includes normalization and rendering with the RAW already prepared,
including any film-resource setup for that step. It does not measure tap latency.
Exact recipes are in `stage5-merrill.json` and `stage5-quattro.json`.

Peak memory is for the entire combined run, not the film step. These passing runs
do not resolve the earlier system-memory-pressure cancellations. Cancellation
behavior, production Rust, the C ABI, and the bundled framework did not change.

The final iPad simulator UI suite passed all three tests: crop/curves, HSL/grading,
and advanced film. The film test also passed on the iPhone simulator. It covers
Cancel, paper selection, manual then automatic paper exposure, grain and halation
changes, Apply, and persistence after backgrounding and restart. Screenshots from
both layouts were inspected. The first iPhone attempt failed because a test tap
hit the switch row rather than its toggle; targeting the toggle fixed the test
without an app change.


## Stage 6 camera matching and Apple RAW evaluation

The Release simulator unit suite passed all 34 tests. The new checks cover the
shared engine's camera profile and film-stock rules, preservation of other edits,
exact restoration of disabled film settings, unavailable profiles, concurrent
edits, and a suspended look operation after switching A to B to A. The signed
Release device build and signature verification passed. That build was installed
and launched on the physical iPad mini 6.

Camera matching UI tests use copied Merrill DP2M0643 and Quattro DP0Q0010 files.
They select Standard, Vivid, and Monochrome, switch to film and back, then check
persistence after backgrounding and restarting. The saved profile is Vivid or
FOV Classic Blue, different from the initial selection and either fixture's
default. This also prevents repeat runs from passing on stale saved data.

The first two tests passed on each simulator. Final review found that saving
Standard could hide a failed save on the Quattro fixture, whose default is
Standard. The tests were strengthened as described above. The final runs passed
both tests on the iPhone 16e and iPad mini (A17 Pro) simulators, using iOS 26.0.1.
Final screenshots from both layouts were inspected.

No physical-device timing or memory benchmark was rerun for this stage. The
production Rust renderer, C ABI, and bundled framework did not change. Earlier
memory-pressure cancellations remain unresolved.

Apple CIRAWFilter was tested on macOS with synthetic DNGs and Sigma exports.
Default-crop baking, ignored user crops in the tested configuration, white-balance
compatibility, and missing physical iOS evidence prevent production integration.
DNG import remains deferred; see [Apple RAW evaluation](APPLE_RAW.md) for the
settings, measurements, supported observations, and required follow-up.
