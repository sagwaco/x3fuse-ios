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

Edit exposure and white balance with native controls. Film processing is disabled
in this first slice. App-local settings are saved atomically in a versioned
`native-edits.json` file. Unsupported or unreadable edit files are preserved.
Desktop sidecar import and export are not implemented yet.

Export a full-resolution sRGB JPEG to Documents/Exports, then use Share or Files.
JPEG exports include an ICC profile and baked orientation. They do not copy capture
EXIF metadata. Exports use unique names. Keep the app in the foreground during
processing; backgrounding cancels active work.

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
slices and compiles the simulator app and test bundle. CI does not establish
physical-device rendering or performance.

## Device benchmark

Place a copied X3F or X3I fixture in the app's Documents/Benchmarks folder. Launch
with `--benchmark` and optionally a fixture basename. Without a basename, the
first supported filename in sorted order is used. Results are written to
Documents/Benchmarks/report.json. The runner imports a copy, prepares a RAW,
renders a preview, and exports a JPEG. It samples process physical footprint
at 50 ms intervals. These samples are a lower bound on peak memory.

See [performance checks](docs/PERFORMANCE.md) for the fixture matrix and baseline.
Processing timings do not measure tap latency or display frame rate.

## Remaining migration

The first slice covers import, browsing, exposure/WB, local saves, and JPEG export.
Next: device acceptance and responsiveness measurements; desktop sidecar exchange;
remaining edit controls and film; TIFF/DNG export; metadata and larger libraries.
Direct GPU presentation and SFD merging need separate memory and timing evidence.

The source uses GPL-3.0-only. Preserve the renderer attribution and bundled notices.
