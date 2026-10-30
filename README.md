# X3Fuse Native

Native Swift iPhone and iPad RAW editor prototype. The app uses SwiftUI controls,
a MetalKit viewport with pinch zoom, pan, and double-tap fit, and the existing calibrated Rust renderer through a C ABI.
Minimum deployment target: iOS and iPadOS 17. Builds target ARM64 devices and
Apple Silicon simulators.

## Build

Install Xcode, Rust through rustup, and XcodeGen. Complete Xcode first-launch setup.

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
bash scripts/build-engine.sh
xcodegen generate
open X3FuseNative.xcodeproj
```

Select the X3FuseNative target, enable automatic signing, choose your development
team, select your connected device, and run. Use Release for performance checks.
The app has bundle ID `com.sagwa.X3Fuse.native`; it can coexist with X3Fuse.
Node, Vite, and Tauri are not required. Rebuild the framework after engine changes.

## Current workflow

Import X3F or X3I files through Files. The app copies each file into a unique
Application Support asset directory. X3I uses the middle exposure. Originals
remain unchanged. The library restores imported copies at launch.

Edit exposure, white balance, light, and color with native controls. Enable film
and choose a stock. New photos start with film disabled. The app keeps the full
canonical recipe, including settings that have no native control yet. App-local
edits are saved atomically in a versioned `native-edits.json` file. Version-1
native settings migrate once against the source defaults. Unsupported, unreadable,
or externally changed edit files are preserved.

Import a desktop `.x3fuse.json` sidecar for the selected photo and confirm replacement
of the current edits. Its source hash must match. Export a sidecar to a unique folder
under Documents/Exports with the exact original filename plus `.x3fuse.json`.
Use Share or Files to copy it beside the matching desktop RAW. Imported files remain
unchanged. X3I recipes that require merging are rejected on iOS.

Export a full-resolution sRGB JPEG, rendered 16-bit sRGB TIFF, or Original DNG to
Documents/Exports, then use Share or Files. JPEG and TIFF include the edits. Original
DNG does not bake edits. DNG uses the bundled lens corrections where supported and
includes core EXIF metadata only. JPEG includes an ICC profile and baked orientation;
rendered exports do not copy capture EXIF metadata. Exports use unique names.
Keep the app in the foreground during processing; backgrounding cancels active work.

The viewport receives RGBA pixels from the shared GPU renderer and displays them
through MetalKit. It still reads pixels back from the GPU and uploads the display
texture. Direct GPU presentation remains a measured follow-up, not a current claim.

## Engine and checks

`Engine/` owns the C ABI, cancellation, sessions, and export publication.
`Vendor/x3f-render` is an unchanged, pinned renderer snapshot; see
[provenance](Vendor/README.md). Replace this snapshot with a shared versioned
package when the required renderer revision is published. `x3f-core` is pinned to
0.4.0. No local checkout outside this repository is required.

```sh
cargo test --manifest-path Engine/Cargo.toml --locked --release
cargo fmt --manifest-path Engine/Cargo.toml -- --check
```

Run the X3FuseNative scheme tests on an iOS simulator. CI builds both Rust
slices and runs the simulator tests. CI does not establish
physical-device rendering or performance.

## Device benchmark

Place a copied X3F or X3I fixture in the app's Documents/Benchmarks folder. Launch
with `--benchmark` and optionally a fixture basename. Without a basename, the
first supported filename in sorted order is used. Results are written to
Documents/Benchmarks/report.json. The runner imports a copy, prepares a RAW,
renders a preview, and exports JPEG, TIFF, and DNG. It also checks a sidecar round
trip and renders one film preview. The report records each export time and the
exact film recipe. It samples process physical footprint at 50 ms intervals.
These samples are a lower bound on peak memory.

See [performance checks](docs/PERFORMANCE.md) for the fixture matrix and baseline.
Processing timings do not measure tap latency or display frame rate.

## Remaining migration

The current app covers X3F/X3I import, browsing, local edits, desktop sidecar exchange,
light and color controls, film stock selection, and JPEG/TIFF/DNG export. Remaining
work includes advanced edit controls, DNG import, metadata parity, larger libraries,
and measured UI latency. Original TIFF conversion is not included. Reset stores an
explicit default recipe instead of deleting the local edit file. Direct GPU
presentation and SFD merging need separate memory and timing evidence.

The source uses GPL-3.0-only. Preserve the renderer attribution and bundled notices.
