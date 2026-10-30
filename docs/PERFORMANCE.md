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
