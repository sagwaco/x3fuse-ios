# Apple RAW DNG import

CIRAWFilter runs on a serial worker and passes linear RGB to the shared Rust
renderer. Stage 8 uses a preview with a longest edge of at most 3072 pixels for
editing, preserving the original dimensions for crop and film effects. No LibRaw dependency was added. The original DNG is
copied into a unique asset directory and is never changed.

## Supported subset

- Classic TIFF DNG version 1.0 through 1.7, with one full-resolution CFA or LinearRaw IFD.
- At most 100 million stored and active pixels for preview editing. Full-resolution export remains limited to 24 million stored and output pixels, with enough available process memory.
- A valid ActiveArea, or the stored rectangle when ActiveArea is absent. Integer DefaultCrop origin and size must fit inside that area. Missing DefaultCrop is accepted only with zero active origin. The validated default crop defines the original editing frame.
- DefaultUserCrop must be absent or full-frame. DefaultScale must be absent or [1, 1]. Ambiguous geometry is rejected.
- As-shot white balance only. Custom temperature, tint, gains, demosaic modes, Sigma camera profiles, sensor monochrome, RAW denoise, and fill light are rejected. Film simulation and ordinary rendered-image adjustments remain available.
- JPEG and 16-bit TIFF export reopen a full-resolution decode for supported files within the 24 MP limit. Larger-image export is disabled. The engine rejects proxy exports, so an enlarged preview can never become a full-resolution export. DNG conversion export and desktop sidecar exchange remain unavailable for DNG inputs.

Geometry is read from the actual RAW IFD with a bounded TIFF parser. ImageIO can
report thumbnail geometry while decoding a different RAW crop. The parser checks
field types, counts, offsets, duplicate tags, graph cycles, and conflicting RAW images.
Apple native dimensions at scale one must match the proven default crop. Scaled
output must match the planned dimensions within integer rounding. A supported DNG
decoder is selected explicitly if Apple initially chooses a camera-native decoder;
an existing supported DNG decoder is retained.

Decode forces orientation up, applies file BaselineExposure once, and retains
original EXIF orientation for the Rust renderer. RGBA32f uses extended linear sRGB;
finite negative values and values above one are retained. Reduced output can have
non-unit coverage alpha from resampling: finite positive alpha is unpremultiplied,
then set to one, with finite RGB checked again. Full-size output still requires
opaque alpha. The borrowed C buffer is
validated and copied into owned RGB. Cancellation and source hashes are checked
around the blocking Apple decode and bridge. An in-progress Apple decode cannot
be interrupted inside the framework call.

Native DNG documents use inner schema 3 with an Apple bridge, OS build, and decoder
identity, inside the existing native schema 2 envelope. A changed identity rejects
old edits without overwriting them. An OS update may therefore require a future
explicit migration before old DNG edits can reopen. Sigma document behavior remains
separate. Newly accepted implicit-active-area or cropped files add
`:default-crop-v1` to the identity. Preview dimensions are not stored in recipes.
No desktop LibRaw color or white-balance parity is claimed.

Preview memory estimates cover the output and bridge buffers. Apple can allocate
additional internal decoding memory, so the pixel cap is not a guarantee that every
100 MP file will open on every device. Export releases the preview before full
decode, verifies source hash, decoder identity and original dimensions, and releases
the full session on success or failure. The next edit reopens a preview.

## Stage 7 physical validation (before preview editing)

The iPad mini 6 on iPadOS 26.5.2, build 23F84, used decoder 8.dng.
The final production-helper matrix had 63 cases: 29 accepted and 34 expected
rejections. It covered Bayer and LinearRaw, all eight orientations, exposure -1/0/+1
and missing exposure, non-full crops, and conflicting thumbnail/RAW metadata.
Both malicious crop fixtures were rejected; both full-RAW controls were accepted.
The parser also passed 22 independent malformed-metadata and precedence checks.

The real Merrill DNG decoded at 4704×3136 and completed preview rendering, JPEG,
16-bit TIFF, native identity round-trip, mismatched identity rejection, unsupported
white-balance rejection, and cancellation checks. The source hash was unchanged.
Peak sampled footprint was 862,946,680 bytes for the full bridge/export harness.
The tested Quattro DNG has a non-full DefaultUserCrop and is rejected.

Captured evidence: [helper matrix](benchmarks/stage7-apple-helper.jsonl),
[full bridge/export report](benchmarks/stage7-apple-engine.json). These are measured
fixture results, not general camera coverage or memory guarantees.

Pending edits can remain in memory if the matching session was released and the app
is inactive when validation runs. Memory warnings still cancel processing; no
resource-pressure fix is claimed. iOS 17 through 25 were not physically tested.

## Historical stage 6 macOS investigation

The following report records the earlier research before production integration.
Its recommendation to defer was superseded by the physical checks above. Its timing
figures are macOS evidence, not iOS performance results.

Reference: [Apple CIRAWFilter documentation](https://developer.apple.com/documentation/coreimage/cirawfilter).

The temporary probe sources and captured results were stored in
`/private/tmp/x3fuse-apple-raw-probe`. They are not repository dependencies.

```text
Apple RAW bridge probe, macOS only
Host: macOS 27.0.1, build 26A434, arm64. Swift 6.4. Decoder selected by Apple: 8.dng for these synthetic and Sigma files (supported list also includes 9.dng). No production or Git changes. All created artifacts are in this directory.

Reproduce:
python3 build_fixtures.py
xcrun swiftc -O -module-cache-path modules probe.swift -o probe-final
./probe-final <files> > results.jsonl
./probe-final --restore-baseline <EV files> > baseline-restored.jsonl
./probe-final --keep-orientation <orientation files> > oriented.jsonl
python3 check_probe.py
RAW services may require execution outside the agent sandbox. The assertion check passes against captured results.

Decode settings:
CIContext working color space extendedLinearSRGB, working format RGBAf; render destination extendedLinearSRGB RGBAf. exposure=0, baselineExposure=0, shadowBias=0, boostAmount=0, boostShadowAmount=0, localToneMapAmount=0, gamut mapping false. Draft false, scale 1 except explicitly labeled real-small results. Supported detail, sharpness, contrast, chroma/luma noise reduction, moire, despeckle and lens correction disabled. As-shot WB left as read. Orientation forced up except oriented.jsonl. No EDR display look enabled. Bitmap starts as NaN to detect missing writes.

Synthetic builder:
Little-endian IFD writer ported from desktop x3f-dng/tests.rs, uncompressed 16-bit Bayer and three-channel LinearRaw; 960x800; black64 white4095; camera XYZ-to-linear-sRGB matrix and neutral[.5,1,.8]; flat scene .25. Four quadrants have scene values [.1,.2,.4,.7] in stored top-left, top-right, bottom-left, bottom-right. 96x80 versions gave a nonnil filter but zero nativeSize/empty output extent; 960x800 works. No minimum supported size inferred.

Exposure:
Bayer clear-baseline means for tag -1,0,+1: .2500210951 each.
Linear clear-baseline means for tag -1,0,+1: .2500169675 each.
Restoring baselineExposure to the captured file-tag value gives Bayer means .1250105525,.2500210951,.5000422100; linear .1250084912,.2500169675,.5000339647. Ratios .5,1,2 pass 1e-6 relative tolerance.
Missing BaselineExposure tag: ImageIO DNG properties omit it, Apple baselineExposure defaults0, means match EV0. Read the file tag explicitly with default0, rather than assuming every Apple's inferred default equals a file tag. These probes confirm one-time restore semantics on tested files only.

Crop and orientation:
Stored image960x800; ActiveArea[top,left,bottom,right]=[80,120,720,840], so active720x640. DefaultCropOrigin[x,y]=[80,60], size480x400. Apple nativeSize and output are480x400: default crop is already baked. Pixel means and quadrant boundaries agree with this crop.
DefaultUserCrop[top,left,bottom,right]=[.1,.125,.9,.875] yields exactly the same sampled 4x4 RGBA grid, corner pixels, and full-image mean as the no-user-crop case for BOTH Bayer and LinearRaw. Apple ignores this user framing in this configuration. Metadata presence independently confirmed by ExifTool.
Forcing orientation up yields identical 480x400 pixels for original EXIF1..8. Keeping original orientation gives the expected 8 corner permutations and dimensions400x480 for tags5..8. Bitmap first row is the stored top row; no extra vertical flip needed with this context.render(toBitmap:) path.
Explicit full-active DefaultCropOrigin[0,0]/Size[720,640] yields720x640.
Nonzero ActiveArea with no explicit DefaultCrop yielded unexpected600x560, not720x640, for both layouts. Treat this case as unsupported until understood. Do not infer crop geometry from nativeSize or PixelWidth alone: raw.properties PixelWidth/Height report cropped dimensions.

Floating-point evidence:
Full-resolution Sigma outputs are finite with opaque alpha and retain negatives and values above1.
Merrill4704x3136: min-.03762180 max4.48933649 mean.0409926163.
Quattro5424x3616: min-.20414022 max1.38154817 mean.0360416754.
Adobe 02_jxl_linear_raw_float.dng decodes at scale1/8 with finite output, as do integer LinearRaw01 and Bayer03. 04..13 decode. Names07/08 refer to float gain maps; their main images are integer, so they are not evidence of main-image float16/32 decode. Adobe14_hdr_sdr_profiles gives nil output.
Our uncompressed32-bit float HDR fixture passes ExifTool validation but Apple gives nil output. This is a rejected fixture, not proof that all float32 DNGs are unsupported. Do not claim general float layout coverage.

Real Sigma crop metadata:
Merrill: raw SubIFD4704x3136; ActiveArea[0,0,3136,4704]; no DefaultCropOrigin/Size tags; DefaultUserCrop[0,0,1,1]; Orientation1; BaselineExposure1.9996; profile name Monochrome.
Quattro: raw SubIFD5424x3616; ActiveArea[0,0,3616,5424]; no DefaultCropOrigin/Size; DefaultUserCrop[.178097,0,.821903,1]; Orientation1; BaselineExposure0; profile name Teal and Orange.
Both ActiveArea and DefaultUserCrop appear in CIRAWFilter.properties DNG dictionary, including actual arrays, not only ExifTool output. These fields are available in the iOS ImageIO headers, but availability does not establish per-file reliability on physical iOS.

Full-resolution timing and memory, separate process per Sigma file, warm filesystem/cache, optimized Swift:
Merrill preparation+render416.50ms, bitmap render206.47ms, process wall0.73s; max RSS757284864 bytes (722.20MiB); peak footprint710444328 bytes.
Quattro preparation+render431.12ms, bitmap render235.30ms, process wall0.57s; max RSS973832192 bytes (928.72MiB); peak footprint918128056 bytes.
The probe includes a full RGBA32f buffer, Core Image allocations, and streaming stats, but no Rust RGB copy or renderer texture. These are not mobile memory budgets or cold-start benchmarks. Times exclude statistics after render. No claim of pixel parity with desktop LibRaw/color processing.

Recommendation:
Keep production deferred pending physical iOS26 evidence and crop contract decision. A possible future smallest subset is as-shot-WB-only, full-active-area decode: require finite validated ActiveArea; explicit DefaultCropOrigin[0,0]/Size equal active extent, or separately validated absent-crop/origin-zero case; full or absent user crop; unit DefaultScale; finite integral output extent exactly equal expected active dimensions after forcing up; reject anything ambiguous. Require source-specific checking of decoder version, metadata, data count, finite opaque pixels, source identity and memory budget. Reject unsupported WB/gains/picker and ALL explicit demosaic modes, not just hide UI.
Metadata can express the needed equality on iOS, but the macOS probe cannot guarantee the iOS decoder honors it. Merrill meets the observed origin-zero/no-user-crop candidate; this Quattro does not meet the no-user-crop subset. Supporting user crop later requires correct normalized recipe mapping while keeping the desktop active-area coordinate system. Supporting already-baked nonfull default crops requires a larger coordinate/export contract; do not silently apply desktop crop twice.
```

Stage 8 preview, spatial, export lifecycle, and memory measurements are recorded
in [the performance report](PERFORMANCE.md#stage-8-preview-based-dng-editing), with
raw reports and the exact helper source hashes used for physical validation.
