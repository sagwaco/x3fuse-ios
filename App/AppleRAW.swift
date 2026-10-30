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
    let orientation: UInt16
    let sourceRevision: String
    let decoderIdentity: String
    let baselineExposure: Double
    let asShotTemperature: Float
}

struct AppleRAWImage {
    let rgba: [Float]
    let metadata: AppleRAWMetadata
}

enum AppleRAW {
    static let maximumPixels = 24_000_000

    struct SourceGeometry {
        let dng: [String: Any]
        let orientation: UInt16
        let baselineExposure: Double
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
              let storedHeight = raw[257], storedHeight.count == 1,
              let active = raw[50829], active.count == 4,
              active[0] >= 0, active[1] >= 0, active[2] <= storedHeight[0], active[3] <= storedWidth[0] else {
            throw AppleRAWError("The DNG has no proven full RAW geometry or version.")
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
        return SourceGeometry(dng: dng, orientation: UInt16(orientation[0]), baselineExposure: baseline[0])
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

    static func dimensions(dng: [String: Any], extent: CGRect, availableMemory: UInt64) throws -> (Int, Int) {
        let active = try numbers(dng[kCGImagePropertyDNGActiveArea as String], count: 4)
        guard active.allSatisfy({ $0 >= 0 && $0 <= Double(UInt32.max) && $0.rounded() == $0 }),
              active[2] > active[0], active[3] > active[1] else {
            throw AppleRAWError("The DNG active area is invalid.")
        }
        let width = active[3] - active[1], height = active[2] - active[0]
        let origin = dng[kCGImagePropertyDNGDefaultCropOrigin as String]
        let size = dng[kCGImagePropertyDNGDefaultCropSize as String]
        if origin != nil || size != nil {
            guard try numbers(origin, count: 2) == [0, 0],
                  try numbers(size, count: 2) == [width, height] else {
                throw AppleRAWError("This DNG default crop does not contain the full active area.")
            }
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
              width * height <= Double(maximumPixels) else {
            throw AppleRAWError("The RAW output is not a supported full-resolution active area.")
        }
        let pixels = UInt64(width) * UInt64(height)
        guard availableMemory >= pixels * 64 + 128 * 1024 * 1024 else {
            throw AppleRAWError("Not enough available memory to decode the full-resolution DNG.")
        }
        return (Int(width), Int(height))
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

    // Call this helper on a background serial queue. It always decodes at native resolution.
    static func decode(url: URL, availableMemory: UInt64, checkCancellation: () throws -> Void) throws -> AppleRAWImage {
        try autoreleasepool {
            try checkCancellation()
            let revision = try sourceHash(url, checkCancellation: checkCancellation)
            let source = try sourceGeometry(url, checkCancellation: checkCancellation)
            try checkCancellation()
            guard let raw = CIRAWFilter(imageURL: url),
                  raw.properties[kCGImagePropertyDNGDictionary as String] != nil else {
                throw AppleRAWError("Apple RAW does not support this DNG.")
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
            _ = try dimensions(dng: dng, extent: CGRect(origin: .zero, size: raw.nativeSize), availableMemory: availableMemory)
            try checkCancellation()
            guard let image = raw.outputImage else { throw AppleRAWError("Apple RAW could not decode this DNG.") }
            try checkCancellation()
            let (width, height) = try dimensions(dng: dng, extent: image.extent, availableMemory: availableMemory)
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
            for index in stride(from: 0, to: rgba.count, by: 4) {
                if index % 65536 == 0 { try checkCancellation() }
                guard rgba[index].isFinite, rgba[index + 1].isFinite, rgba[index + 2].isFinite, rgba[index + 3] == 1 else {
                    throw AppleRAWError("Apple RAW returned incomplete or invalid linear pixels.")
                }
            }
            guard try sourceHash(url, checkCancellation: checkCancellation) == revision else {
                throw AppleRAWError("The DNG changed during decoding. The source was kept unchanged.")
            }
            try checkCancellation()
            let os = ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: " ", with: "_")
            let identity = "apple-raw-v1:\(os):\(raw.decoderVersion.rawValue)"
            return AppleRAWImage(rgba: rgba, metadata: AppleRAWMetadata(width: UInt32(width), height: UInt32(height),
                orientation: UInt16(orientation), sourceRevision: revision, decoderIdentity: identity,
                baselineExposure: baseline, asShotTemperature: raw.neutralTemperature))
        }
    }
}
