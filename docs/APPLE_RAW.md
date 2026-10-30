# Apple RAW evaluation

Stage 6 evaluated CIRAWFilter as an alternative to LibRaw for future DNG import.
No production decoder, import format, Rust ABI, or renderer changed.
The measurements below are macOS evidence, not iOS performance results.

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
