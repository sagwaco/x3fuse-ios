import Foundation
import CoreImage
import ImageIO
import CryptoKit
import CoreFoundation

struct AppleRAWError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct AppleRAWMetadata: Codable {
    let width: UInt32
    let height: UInt32
    let originalWidth: UInt32
    let originalHeight: UInt32
    let orientation: UInt16
    let sourceRevision: String
    let decoderIdentity: String
    let baselineExposure: Double
    let asShotTemperature: Float
}

struct AppleRAWImage {
    let rgba: [Float]
    let metadata: AppleRAWMetadata
    let canExportFullResolution: Bool
}

enum AppleRAW {
    static let maximumPixels = 24_000_000
    static let maximumSourcePixels = 100_000_000
    static let previewMaximumEdge = 3072

    enum DecodeMode: Equatable { case preview, full }

    struct DecodePlan {
        let width: Int
        let height: Int
        let scale: Float

        func outputDimensions(_ extent: CGRect, availableMemory: UInt64) throws -> (Int, Int) {
            let expectedWidth = Double(width) * Double(scale)
            let expectedHeight = Double(height) * Double(scale)
            guard extent.origin == .zero, extent.width.isFinite, extent.height.isFinite,
                  extent.width > 0, extent.height > 0,
                  extent.width.rounded() == extent.width, extent.height.rounded() == extent.height,
                  (floor(expectedWidth)...ceil(expectedWidth)).contains(Double(extent.width)),
                  (floor(expectedHeight)...ceil(expectedHeight)).contains(Double(extent.height)),
                  extent.width <= CGFloat(width), extent.height <= CGFloat(height),
                  scale == 1 || max(extent.width, extent.height) <= CGFloat(previewMaximumEdge),
                  extent.width * extent.height <= CGFloat(maximumPixels) else {
                throw AppleRAWError("The RAW output does not match the planned full-area decode.")
            }
            let pixels = UInt64(extent.width) * UInt64(extent.height)
            guard availableMemory >= pixels * 64 + 128 * 1024 * 1024 else {
                throw AppleRAWError("Not enough available memory to decode the DNG.")
            }
            return (Int(extent.width), Int(extent.height))
        }
    }

    static func decodePlan(dng: [String: Any], nativeSize: CGSize, mode: DecodeMode) throws -> DecodePlan {
        let (width, height) = try originalDimensions(dng: dng, extent: CGRect(origin: .zero, size: nativeSize))
        if mode == .full { try validateFullExport(width: width, height: height) }
        var scale = mode == .preview ? min(1, Float(previewMaximumEdge) / Float(max(width, height))) : 1
        if Double(max(width, height)) * Double(scale) > Double(previewMaximumEdge), mode == .preview {
            scale = scale.nextDown
        }
        return DecodePlan(width: width, height: height, scale: scale)
    }

    static func validateFullExport(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumPixels / height else {
            throw AppleRAWError("JPEG and TIFF export is unavailable for DNG images above 24 megapixels. You can edit and save a reduced preview. Full-resolution export is planned.")
        }
    }

    struct SourceGeometry {
        let dng: [String: Any]
        let orientation: UInt16
        let baselineExposure: Double
        let usesDefaultCropIdentity: Bool
        let storedWidth: Int
        let storedHeight: Int

        func canExportFullResolution(width: Int, height: Int) -> Bool {
            do {
                try AppleRAW.validateFullExport(width: storedWidth, height: storedHeight)
                try AppleRAW.validateFullExport(width: width, height: height)
                return true
            } catch { return false }
        }
    }

    static func decoderIdentity(os: String, version: String, usesDefaultCrop: Bool) -> String {
        "apple-raw-v1:\(os):\(version)" + (usesDefaultCrop ? ":default-crop-v1" : "")
    }

    static func dngDecoder(current: CIRAWDecoderVersion, supported: [CIRAWDecoderVersion]) throws -> CIRAWDecoderVersion {
        let selected: CIRAWDecoderVersion? = current.rawValue.hasSuffix(".dng")
            ? current : supported.filter { $0.rawValue.hasSuffix(".dng") }.max {
                $0.rawValue.compare($1.rawValue, options: .numeric) == .orderedAscending
            }
        guard let selected, supported.contains(selected) else {
            throw AppleRAWError("Apple RAW has no supported DNG decoder for this image.")
        }
        return selected
    }

    // ImageIO can merge thumbnail geometry into RAW properties. Read the unique RAW IFD instead.
    static func sourceGeometry(_ url: URL, checkCancellation: () throws -> Void) throws -> SourceGeometry {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            try checkCancellation()
            guard count >= 0, offset <= length, UInt64(count) <= length - offset else {
                throw AppleRAWError("The DNG has an out-of-bounds metadata offset.")
            }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else {
                throw AppleRAWError("The DNG metadata is incomplete.")
            }
            return Array(data)
        }
        let header = try read(0, 8)
        guard Array(header[0..<2]) == [73, 73] || Array(header[0..<2]) == [77, 77] else {
            throw AppleRAWError("The DNG TIFF byte order is unsupported.")
        }
        let little = header[0] == 73
        func uint(_ bytes: [UInt8], _ start: Int, _ size: Int) -> UInt64 {
            (0..<size).reduce(0) { value, index in
                value | UInt64(bytes[start + index]) << ((little ? index : size - index - 1) * 8)
            }
        }
        guard uint(header, 2, 2) == 42 else { throw AppleRAWError("Only classic TIFF DNG files are supported.") }
        var pending = [uint(header, 4, 4)]
        var visited = Set<UInt64>()
        var root: [UInt16: [Double]]?
        var raw: [UInt16: [Double]]?
        let wanted: Set<UInt16> = [254, 256, 257, 262, 274, 330, 50706, 50718, 50719, 50720, 50730, 50829, 51125]
        while let offset = pending.popLast() {
            guard offset >= 8, visited.count < 32, visited.insert(offset).inserted else {
                throw AppleRAWError("The DNG IFD graph is ambiguous or too large.")
            }
            let count = Int(uint(try read(offset, 2), 0, 2))
            guard count <= 512 else { throw AppleRAWError("The DNG has too many metadata entries.") }
            let entries = try read(offset + 2, count * 12 + 4)
            var tags: [UInt16: [Double]] = [:]
            var seen = Set<UInt16>()
            for index in 0..<count {
                let start = index * 12
                let tag = UInt16(uint(entries, start, 2))
                guard seen.insert(tag).inserted else { throw AppleRAWError("The DNG has duplicate metadata tags.") }
                guard wanted.contains(tag) else { continue }
                let type = uint(entries, start + 2, 2)
                let elements = Int(uint(entries, start + 4, 4))
                let bytesPerElement: Int
                switch type {
                case 1: bytesPerElement = 1
                case 3: bytesPerElement = 2
                case 4, 13: bytesPerElement = 4
                case 5, 10: bytesPerElement = 8
                default: throw AppleRAWError("The DNG geometry uses an unsupported TIFF field type.")
                }
                let validField: Bool
                switch tag {
                case 254: validField = type == 4 && elements == 1
                case 256, 257: validField = (type == 3 || type == 4) && elements == 1
                case 262, 274: validField = type == 3 && elements == 1
                case 330: validField = (type == 4 || type == 13) && (1...32).contains(elements)
                case 50706: validField = type == 1 && elements == 4
                case 50718: validField = type == 5 && elements == 2
                case 50719, 50720: validField = (type == 3 || type == 4 || type == 5) && elements == 2
                case 50730: validField = type == 10 && elements == 1
                case 50829: validField = type == 4 && elements == 4
                case 51125: validField = type == 5 && elements == 4
                default: validField = false
                }
                guard validField else {
                    throw AppleRAWError("The DNG metadata count or type is invalid.")
                }
                let byteCount = elements * bytesPerElement
                let value = byteCount <= 4 ? Array(entries[(start + 8)..<(start + 8 + byteCount)])
                    : try read(uint(entries, start + 8, 4), byteCount)
                tags[tag] = try (0..<elements).map { element in
                    let start = element * bytesPerElement
                    if type == 5 || type == 10 {
                        let numerator = uint(value, start, 4), denominator = uint(value, start + 4, 4)
                        let n = type == 10 ? Double(Int32(bitPattern: UInt32(numerator))) : Double(numerator)
                        let d = type == 10 ? Double(Int32(bitPattern: UInt32(denominator))) : Double(denominator)
                        guard d != 0 else { throw AppleRAWError("The DNG has a zero rational denominator.") }
                        return n / d
                    }
                    return Double(uint(value, start, bytesPerElement))
                }
            }
            if root == nil { root = tags }
            if let photo = tags[262], photo == [32803] || photo == [34892] {
                guard raw == nil, tags[254] == nil || tags[254] == [0] else {
                    throw AppleRAWError("The DNG does not have one unambiguous full-resolution RAW image.")
                }
                raw = tags
            }
            let next = uint(entries, count * 12, 4)
            if next != 0 { pending.append(next) }
            pending.append(contentsOf: (tags[330] ?? []).map(UInt64.init))
        }
        guard let root, let raw, let version = root[50706], version.count == 4,
              let storedWidth = raw[256], storedWidth.count == 1,
              let storedHeight = raw[257], storedHeight.count == 1 else {
            throw AppleRAWError("The DNG has no proven full RAW geometry or version.")
        }
        guard storedWidth[0] > 0, storedHeight[0] > 0,
              storedWidth[0] * storedHeight[0] <= Double(maximumSourcePixels) else {
            throw AppleRAWError("DNG sources above 100 megapixels are not supported.")
        }
        let active = raw[50829] ?? [0, 0, storedHeight[0], storedWidth[0]]
        guard active.count == 4, active[0] >= 0, active[1] >= 0,
              active[2] <= storedHeight[0], active[3] <= storedWidth[0] else {
            throw AppleRAWError("The DNG active area is outside the stored RAW image.")
        }
        try validateVersion(version)
        guard raw[50706] == nil || raw[50706] == version else {
            throw AppleRAWError("The DNG has conflicting version metadata.")
        }
        let orientation = raw[274] ?? root[274] ?? [1]
        let baseline = raw[50730] ?? root[50730] ?? [0]
        guard orientation.count == 1, (1...8).contains(orientation[0]), orientation[0].rounded() == orientation[0],
              baseline.count == 1 else { throw AppleRAWError("The RAW orientation or exposure metadata is malformed.") }
        let names: [UInt16: String] = [50829: kCGImagePropertyDNGActiveArea as String,
            50719: kCGImagePropertyDNGDefaultCropOrigin as String, 50720: kCGImagePropertyDNGDefaultCropSize as String,
            51125: kCGImagePropertyDNGDefaultUserCrop as String, 50718: kCGImagePropertyDNGDefaultScale as String]
        var dng: [String: Any] = [:]
        for (tag, name) in names { if let value = raw[tag] { dng[name] = value } }
        dng[kCGImagePropertyDNGActiveArea as String] = active
        let origin = raw[50719] ?? [0, 0]
        let size = raw[50720] ?? [active[3] - active[1], active[2] - active[0]]
        let usesDefaultCrop = raw[50829] == nil || origin != [0, 0]
            || size != [active[3] - active[1], active[2] - active[0]]
        return SourceGeometry(dng: dng, orientation: UInt16(orientation[0]), baselineExposure: baseline[0],
                              usesDefaultCropIdentity: usesDefaultCrop,
                              storedWidth: Int(storedWidth[0]), storedHeight: Int(storedHeight[0]))
    }

    static func numbers(_ value: Any?, count: Int) throws -> [Double] {
        guard let array = value as? [Any], array.count == count else {
            throw AppleRAWError("The DNG has missing or malformed geometry metadata.")
        }
        return try array.map { item in
            guard let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw AppleRAWError("The DNG has invalid numeric metadata.")
            }
            return number.doubleValue
        }
    }

    static func validateVersion(_ value: Any?) throws {
        guard let array = value as? [Any], (2...4).contains(array.count) else {
            throw AppleRAWError("The RAW image has no supported DNG version.")
        }
        let version = try numbers(array, count: array.count)
        guard version.allSatisfy({ $0 >= 0 && $0 <= 255 && $0.rounded() == $0 }),
              version[0] == 1, version[1] <= 7 else {
            throw AppleRAWError("This DNG version is not supported.")
        }
    }

    static func originalDimensions(dng: [String: Any], extent: CGRect) throws -> (Int, Int) {
        let active = try numbers(dng[kCGImagePropertyDNGActiveArea as String], count: 4)
        guard active.allSatisfy({ $0 >= 0 && $0 <= Double(UInt32.max) && $0.rounded() == $0 }),
              active[2] > active[0], active[3] > active[1] else {
            throw AppleRAWError("The DNG active area is invalid.")
        }
        let activeWidth = active[3] - active[1], activeHeight = active[2] - active[0]
        guard activeWidth * activeHeight <= Double(maximumSourcePixels) else {
            throw AppleRAWError("DNG active areas above 100 megapixels are not supported.")
        }
        let origin = dng[kCGImagePropertyDNGDefaultCropOrigin as String]
        let size = dng[kCGImagePropertyDNGDefaultCropSize as String]
        var width = activeWidth, height = activeHeight
        if origin != nil || size != nil {
            let cropOrigin = try numbers(origin, count: 2)
            let cropSize = try numbers(size, count: 2)
            guard (cropOrigin + cropSize).allSatisfy({ $0.rounded() == $0 }),
                  cropOrigin.allSatisfy({ $0 >= 0 }), cropSize.allSatisfy({ $0 > 0 }),
                  cropOrigin[0] + cropSize[0] <= activeWidth,
                  cropOrigin[1] + cropSize[1] <= activeHeight else {
                throw AppleRAWError("The DNG default crop is not an integer rectangle inside the active area.")
            }
            width = cropSize[0]
            height = cropSize[1]
        } else if active[0] != 0 || active[1] != 0 {
            throw AppleRAWError("This DNG has ambiguous active-area crop defaults.")
        }
        if let crop = dng[kCGImagePropertyDNGDefaultUserCrop as String] {
            guard try numbers(crop, count: 4) == [0, 0, 1, 1] else {
                throw AppleRAWError("DNG user crops are not supported by this decoder.")
            }
        }
        if let scale = dng[kCGImagePropertyDNGDefaultScale as String] {
            guard try numbers(scale, count: 2) == [1, 1] else {
                throw AppleRAWError("DNG pixel scaling is not supported by this decoder.")
            }
        }
        guard extent.origin.x.isFinite, extent.origin.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.origin == .zero, extent.width == width, extent.height == height,
              width * height <= Double(maximumSourcePixels) else {
            throw AppleRAWError("The RAW native size does not match the validated DNG default crop.")
        }
        return (Int(width), Int(height))
    }

    static func dimensions(dng: [String: Any], extent: CGRect, availableMemory: UInt64) throws -> (Int, Int) {
        let plan = try decodePlan(dng: dng, nativeSize: extent.size, mode: .full)
        return try plan.outputDimensions(extent, availableMemory: availableMemory)
    }

    static func sourceHash(_ url: URL, checkCancellation: () throws -> Void) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try checkCancellation()
            let data = try file.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func validatePixels(_ rgba: inout [Float], isReducedPreview: Bool,
                               checkCancellation: () throws -> Void) throws {
        guard !rgba.isEmpty, rgba.count % 4 == 0 else {
            throw AppleRAWError("Apple RAW returned an invalid pixel buffer.")
        }
        for index in stride(from: 0, to: rgba.count, by: 4) {
            if index % 65536 == 0 { try checkCancellation() }
            let alpha = rgba[index + 3]
            guard rgba[index].isFinite, rgba[index + 1].isFinite, rgba[index + 2].isFinite,
                  alpha.isFinite, isReducedPreview ? alpha > 0 : alpha == 1 else {
                throw AppleRAWError("Apple RAW returned incomplete or invalid linear pixels.")
            }
            if isReducedPreview {
                // Scaled RAW pixels have coverage alpha. Restore linear RGB without clipping.
                rgba[index] /= alpha
                rgba[index + 1] /= alpha
                rgba[index + 2] /= alpha
                guard rgba[index].isFinite, rgba[index + 1].isFinite, rgba[index + 2].isFinite else {
                    throw AppleRAWError("Apple RAW returned invalid normalized linear pixels.")
                }
                rgba[index + 3] = 1
            }
        }
    }

    // Call this helper on a background serial queue.
    static func decode(url: URL, availableMemory: UInt64, mode: DecodeMode = .preview, checkCancellation: () throws -> Void) throws -> AppleRAWImage {
        try autoreleasepool {
            try checkCancellation()
            let revision = try sourceHash(url, checkCancellation: checkCancellation)
            let source = try sourceGeometry(url, checkCancellation: checkCancellation)
            if mode == .full { try validateFullExport(width: source.storedWidth, height: source.storedHeight) }
            let active = try numbers(source.dng[kCGImagePropertyDNGActiveArea as String], count: 4)
            let cropSize = try numbers(source.dng[kCGImagePropertyDNGDefaultCropSize as String]
                ?? [active[3] - active[1], active[2] - active[0]], count: 2)
            let sourceSize = CGSize(width: cropSize[0], height: cropSize[1])
            let plan = try decodePlan(dng: source.dng, nativeSize: sourceSize, mode: mode)
            _ = try plan.outputDimensions(CGRect(x: 0, y: 0,
                width: ceil(Double(plan.width) * Double(plan.scale)),
                height: ceil(Double(plan.height) * Double(plan.scale))), availableMemory: availableMemory)
            try checkCancellation()
            guard let raw = CIRAWFilter(imageURL: url) else {
                throw AppleRAWError("Apple RAW does not support this DNG.")
            }
            let decoder = try dngDecoder(current: raw.decoderVersion, supported: raw.supportedDecoderVersions)
            raw.decoderVersion = decoder
            guard raw.decoderVersion == decoder,
                  raw.properties[kCGImagePropertyDNGDictionary as String] != nil else {
                throw AppleRAWError("Apple RAW could not select the supported DNG decoder.")
            }
            try checkCancellation()
            let dng = source.dng
            let orientation = source.orientation
            guard raw.orientation.rawValue == orientation, raw.decoderVersion.rawValue.hasSuffix(".dng") else {
                throw AppleRAWError("The DNG decoder or orientation is unsupported.")
            }
            let baseline = source.baselineExposure
            guard abs(baseline) <= 16, Float(baseline).isFinite, raw.neutralTemperature.isFinite,
                  (500...50000).contains(raw.neutralTemperature) else {
                throw AppleRAWError("The DNG exposure or white balance metadata is unsupported.")
            }
            raw.exposure = 0
            raw.baselineExposure = Float(baseline)
            raw.shadowBias = 0
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.localToneMapAmount = 0
            raw.extendedDynamicRangeAmount = 0
            raw.isGamutMappingEnabled = false
            raw.scaleFactor = 1
            raw.isDraftModeEnabled = false
            raw.orientation = .up
            func supports(_ capability: String, _ setter: String, _ enabled: () -> Bool) throws -> Bool {
                // An absent capability selector means this runtime does not expose the feature.
                guard raw.responds(to: NSSelectorFromString(capability)), enabled() else { return false }
                guard raw.responds(to: NSSelectorFromString(setter)) else {
                    throw AppleRAWError("The Apple RAW runtime cannot disable a supported adjustment.")
                }
                return true
            }
            if try supports("isSharpnessSupported", "setSharpnessAmount:", { raw.isSharpnessSupported }) { raw.sharpnessAmount = 0 }
            if try supports("isDetailSupported", "setDetailAmount:", { raw.isDetailSupported }) { raw.detailAmount = 0 }
            if try supports("isContrastSupported", "setContrastAmount:", { raw.isContrastSupported }) { raw.contrastAmount = 0 }
            if try supports("isLuminanceNoiseReductionSupported", "setLuminanceNoiseReductionAmount:", { raw.isLuminanceNoiseReductionSupported }) { raw.luminanceNoiseReductionAmount = 0 }
            if try supports("isColorNoiseReductionSupported", "setColorNoiseReductionAmount:", { raw.isColorNoiseReductionSupported }) { raw.colorNoiseReductionAmount = 0 }
            if try supports("isMoireReductionSupported", "setMoireReductionAmount:", { raw.isMoireReductionSupported }) { raw.moireReductionAmount = 0 }
            // Some iOS RAW runtimes do not implement the SDK's despeckle selectors.
            if try supports("isDespeckleSupported", "setDespeckleAmount:", { raw.isDespeckleSupported }) { raw.despeckleAmount = 0 }
            if try supports("isLensCorrectionSupported", "setLensCorrectionEnabled:", { raw.isLensCorrectionSupported }) { raw.isLensCorrectionEnabled = false }
            // Scaling can change the decoder's native size. Check source geometry first.
            _ = try originalDimensions(dng: dng, extent: CGRect(origin: .zero, size: raw.nativeSize))
            raw.scaleFactor = plan.scale
            try checkCancellation()
            guard let image = raw.outputImage else { throw AppleRAWError("Apple RAW could not decode this DNG.") }
            try checkCancellation()
            let (width, height) = try plan.outputDimensions(image.extent, availableMemory: availableMemory)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
                throw AppleRAWError("The linear RAW color space is unavailable.")
            }
            let context = CIContext(options: [.workingColorSpace: colorSpace, .workingFormat: CIFormat.RGBAf])
            defer { context.clearCaches() }
            var rgba = [Float](repeating: .nan, count: width * height * 4)
            try checkCancellation()
            rgba.withUnsafeMutableBytes { pixels in
                context.render(image, toBitmap: pixels.baseAddress!, rowBytes: width * 16,
                               bounds: image.extent, format: .RGBAf, colorSpace: colorSpace)
            }
            try checkCancellation()
            try validatePixels(&rgba, isReducedPreview: plan.scale < 1, checkCancellation: checkCancellation)
            guard try sourceHash(url, checkCancellation: checkCancellation) == revision else {
                throw AppleRAWError("The DNG changed during decoding. The source was kept unchanged.")
            }
            try checkCancellation()
            let os = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: " ", with: "_")
            let identity = decoderIdentity(os: os, version: raw.decoderVersion.rawValue,
                                           usesDefaultCrop: source.usesDefaultCropIdentity)
            return AppleRAWImage(rgba: rgba, metadata: AppleRAWMetadata(width: UInt32(width), height: UInt32(height),
                originalWidth: UInt32(plan.width), originalHeight: UInt32(plan.height),
                orientation: UInt16(orientation), sourceRevision: revision, decoderIdentity: identity,
                baselineExposure: baseline, asShotTemperature: raw.neutralTemperature),
                canExportFullResolution: source.canExportFullResolution(width: plan.width, height: plan.height))
        }
    }
}
