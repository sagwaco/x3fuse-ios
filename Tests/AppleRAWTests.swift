import XCTest
import ImageIO
import CoreImage
import os
@testable import X3FuseNative

final class AppleRAWTests: XCTestCase {
    #if targetEnvironment(simulator)
    func testSimulatorBudgetAllowsSmallRAWDecode() throws {
        let budget = EngineWorker.rawDecodeMemoryBudget
        print("Simulator RAW memory: process=\(os_proc_available_memory()), decode budget=\(budget)")
        XCTAssertEqual(budget, ProcessInfo.processInfo.physicalMemory)
        let dng = [kCGImagePropertyDNGActiveArea as String: [0, 0, 800, 960]]
        XCTAssertNoThrow(try AppleRAW.dimensions(dng: dng, extent: CGRect(x: 0, y: 0, width: 960, height: 800), availableMemory: budget))
    }
    #endif

    private let extent = CGRect(x: 0, y: 0, width: 720, height: 640)
    private var fullCrop: [String: Any] {
        [kCGImagePropertyDNGActiveArea as String: [80, 120, 720, 840],
         kCGImagePropertyDNGDefaultCropOrigin as String: [0, 0],
         kCGImagePropertyDNGDefaultCropSize as String: [720, 640]]
    }

    func testScaledPreviewNormalizesOnlyValidPremultipliedPixels() throws {
        var pixels: [Float] = [-0.25, 1, 2, 0.5, -2, 4, 8, 2]
        try AppleRAW.validatePixels(&pixels, isReducedPreview: true, checkCancellation: {})
        XCTAssertEqual(pixels, [-0.5, 2, 4, 1, -1, 2, 4, 1])
        var full: [Float] = [-0.5, 2, 4, 1]
        try AppleRAW.validatePixels(&full, isReducedPreview: false, checkCancellation: {})
        XCTAssertEqual(full, [-0.5, 2, 4, 1])
        let invalid: [[Float]] = [
            [1, 2, 3, 0], [1, 2, 3, -1], [1, 2, 3, .nan], [1, 2, 3, .infinity],
            [.nan, 2, 3, 1], [1, .infinity, 3, 1], [1, 2, -.infinity, 1],
            [.greatestFiniteMagnitude, 2, 3, .leastNonzeroMagnitude], [], [1, 2, 3]
        ]
        for var values in invalid {
            XCTAssertThrowsError(try AppleRAW.validatePixels(&values, isReducedPreview: true, checkCancellation: {}))
        }
        for alpha: Float in [0.5, 2, 0, -1, .nan, .infinity] {
            var values: [Float] = [1, 2, 3, alpha]
            XCTAssertThrowsError(try AppleRAW.validatePixels(&values, isReducedPreview: false, checkCancellation: {}))
        }
        XCTAssertThrowsError(try AppleRAW.validatePixels(&full, isReducedPreview: true,
            checkCancellation: { throw CancellationError() }))
    }

    func testDecoderSelectionKeepsDNGAndRejectsNativeFallback() throws {
        let native = CIRAWDecoderVersion(rawValue: "8")
        let older = CIRAWDecoderVersion(rawValue: "7.dng")
        let newest = CIRAWDecoderVersion(rawValue: "8.dng")
        XCTAssertEqual(try AppleRAW.dngDecoder(current: native, supported: [older, newest, native]), newest)
        XCTAssertEqual(try AppleRAW.dngDecoder(current: older, supported: [older, newest]), older)
        let nine = CIRAWDecoderVersion(rawValue: "9.dng")
        let ten = CIRAWDecoderVersion(rawValue: "10.dng")
        XCTAssertEqual(try AppleRAW.dngDecoder(current: native, supported: [ten, native, nine, older]), ten)
        XCTAssertEqual(try AppleRAW.dngDecoder(current: native, supported: [older, ten, nine]), ten)
        XCTAssertThrowsError(try AppleRAW.dngDecoder(current: native, supported: [native]))
        XCTAssertThrowsError(try AppleRAW.dngDecoder(current: newest, supported: [native]))
        XCTAssertThrowsError(try AppleRAW.dngDecoder(current: native, supported: []))
    }

    func testOnlyProvenFullActiveGeometryIsAccepted() throws {
        let dimensions = try AppleRAW.dimensions(dng: fullCrop, extent: extent, availableMemory: .max)
        XCTAssertEqual(dimensions.0, 720)
        XCTAssertEqual(dimensions.1, 640)
        let originZero = [kCGImagePropertyDNGActiveArea as String: [0, 0, 640, 720]]
        XCTAssertNoThrow(try AppleRAW.dimensions(dng: originZero, extent: extent, availableMemory: .max))
        var invalid = fullCrop
        invalid.removeValue(forKey: kCGImagePropertyDNGDefaultCropOrigin as String)
        XCTAssertThrowsError(try AppleRAW.dimensions(dng: invalid, extent: extent, availableMemory: .max))
        invalid.removeValue(forKey: kCGImagePropertyDNGDefaultCropSize as String)
        XCTAssertThrowsError(try AppleRAW.dimensions(dng: invalid, extent: extent, availableMemory: .max))
        for (key, value) in [
            (kCGImagePropertyDNGDefaultUserCrop as String, [0.1, 0, 1, 1]),
            (kCGImagePropertyDNGDefaultScale as String, [2, 1]),
            (kCGImagePropertyDNGDefaultCropOrigin as String, [1, 0]),
            (kCGImagePropertyDNGActiveArea as String, [0, 0, 640.5, 720])
        ] {
            invalid = fullCrop
            invalid[key] = value
            XCTAssertThrowsError(try AppleRAW.dimensions(dng: invalid, extent: extent, availableMemory: .max), key)
        }
    }

    func testGeometryRejectsUnsafeBoundsBeforeAllocation() {
        for extent in [CGRect(x: 1, y: 0, width: 720, height: 640),
                       CGRect(x: 0, y: 0, width: 720.5, height: 640),
                       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 640)] {
            XCTAssertThrowsError(try AppleRAW.dimensions(dng: fullCrop, extent: extent, availableMemory: .max))
        }
        XCTAssertThrowsError(try AppleRAW.dimensions(dng: fullCrop, extent: extent, availableMemory: 0))
        for active: [Any] in [[0, 0, Double.nan, 720], [0, 0, true, 720], [0, 0, "640", 720], [0, 0, 0, 720]] {
            XCTAssertThrowsError(try AppleRAW.dimensions(dng: [kCGImagePropertyDNGActiveArea as String: active], extent: extent, availableMemory: .max))
        }
        XCTAssertThrowsError(try AppleRAW.dimensions(dng: [kCGImagePropertyDNGActiveArea as String: [0, 0, 5000, 5000]],
            extent: CGRect(x: 0, y: 0, width: 5000, height: 5000), availableMemory: .max))
        XCTAssertNoThrow(try AppleRAW.validateVersion([1, 4]))
        for version: Any in [[1, 8], [2, 0], [1, true], [1], "1.4"] {
            XCTAssertThrowsError(try AppleRAW.validateVersion(version))
        }
    }

    func testDecoderMismatchPreservesNativeDNGEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = ImportedAsset(id: UUID(), name: "photo.dng", sourceName: "source.dng", importedAt: Date())
        let directory = root.appendingPathComponent(asset.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = "apple-raw-v1:iOS_26_(Build_23A1):8.dng"
        let document = RecipeDocument(version: 3, sourceRevision: String(repeating: "a", count: 64),
            recipe: try EditSettings(canonicalJSON: "{}"), decoderIdentity: identity)
        let saved = NativeEdits(assetID: asset.id, renderVersion: 1, document: document, decoderIdentity: identity)
        let store = AssetStore(root: root)
        let original = try store.saveEdits(saved, for: asset, replacing: nil)
        guard case .current(let restored) = try store.loadEdits(for: asset).content else { return XCTFail("Missing native DNG edits.") }
        XCTAssertEqual(restored, saved)
        XCTAssertNoThrow(try restored.validateDecoder(identity))
        XCTAssertThrowsError(try restored.validateDecoder(identity + ".changed"))
        XCTAssertThrowsError(try restored.validateDecoder(nil))
        let wire = try JSONSerialization.jsonObject(with: Data(document.json.utf8)) as? [String: Any]
        XCTAssertEqual(wire?["version"] as? Int, 3)
        XCTAssertEqual(wire?["decoderIdentity"] as? String, identity)
        for key in ["width", "height", "originalWidth", "originalHeight", "isProxy"] {
            XCTAssertNil(wire?[key])
            XCTAssertNil((wire?["recipe"] as? [String: Any])?[key])
        }
        var changed = saved
        changed.decoderIdentity = identity + ".changed"
        changed.document.decoderIdentity = changed.decoderIdentity
        XCTAssertThrowsError(try store.saveEdits(changed, for: asset, replacing: original))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("native-edits.json")), original)
        changed = saved
        changed.decoderIdentity = nil
        XCTAssertThrowsError(try store.saveEdits(changed, for: asset, replacing: original))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("native-edits.json")), original)
    }

    func testHashChecksCancellationAndKnownDigest() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(try AppleRAW.sourceHash(url, checkCancellation: {}), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try AppleRAW.sourceHash(url, checkCancellation: { throw CancellationError() }))
        XCTAssertThrowsError(try AppleRAW.decode(url: url, availableMemory: .max, checkCancellation: { throw CancellationError() }))
    }

    func testRAWIFDGeometryCannotBeHiddenByThumbnailTags() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for (cropped, userCrop) in [(false, false), (true, false), (false, true)] {
            try tiffFixture(rawCrop: cropped, rawUserCrop: userCrop).write(to: url)
            let source = try AppleRAW.sourceGeometry(url, checkCancellation: {})
            let extent = CGRect(x: 0, y: 0, width: cropped ? 480 : 960, height: cropped ? 400 : 800)
            if userCrop {
                XCTAssertThrowsError(try AppleRAW.dimensions(dng: source.dng, extent: extent, availableMemory: .max))
            } else {
                XCTAssertNoThrow(try AppleRAW.dimensions(dng: source.dng, extent: extent, availableMemory: .max))
                XCTAssertEqual(source.usesDefaultCropIdentity, cropped)
            }
        }
        var malformed = tiffFixture(rawCrop: false, rawUserCrop: false)
        malformed.replaceSubrange(4..<8, with: [255, 255, 255, 255])
        try malformed.write(to: url)
        XCTAssertThrowsError(try AppleRAW.sourceGeometry(url, checkCancellation: {}))
        try Data([73, 73, 42]).write(to: url)
        XCTAssertThrowsError(try AppleRAW.sourceGeometry(url, checkCancellation: {}))
    }

    func testPreviewPlanKeepsOriginalGeometryAndBoundsDecodedPixels() throws {
        for (width, height) in [(960, 800), (9504, 6336), (9505, 6337), (6337, 9505)] {
            let dng: [String: Any] = [kCGImagePropertyDNGActiveArea as String: [0, 0, height, width]]
            let plan = try AppleRAW.decodePlan(dng: dng, nativeSize: CGSize(width: width, height: height), mode: .preview)
            XCTAssertEqual(plan.width, width)
            XCTAssertEqual(plan.height, height)
            let extent = CGRect(x: 0, y: 0, width: ceil(Double(width) * Double(plan.scale)),
                                height: ceil(Double(height) * Double(plan.scale)))
            let decoded = try plan.outputDimensions(extent, availableMemory: .max)
            XCTAssertNoThrow(try plan.outputDimensions(CGRect(x: 0, y: 0,
                width: floor(Double(width) * Double(plan.scale)),
                height: floor(Double(height) * Double(plan.scale))), availableMemory: .max))
            XCTAssertLessThanOrEqual(max(decoded.0, decoded.1), AppleRAW.previewMaximumEdge)
            if width == 960 { XCTAssertEqual(plan.scale, 1) }
            XCTAssertThrowsError(try plan.outputDimensions(extent.offsetBy(dx: 1, dy: 0), availableMemory: .max))
            XCTAssertThrowsError(try plan.outputDimensions(extent, availableMemory: 0))
            XCTAssertThrowsError(try plan.outputDimensions(CGRect(x: 0, y: 0, width: extent.width - 2,
                height: extent.height), availableMemory: .max))
        }
        XCTAssertThrowsError(try AppleRAW.decodePlan(dng: fullCrop, nativeSize: CGSize(width: 719, height: 640), mode: .preview))
        let huge: [String: Any] = [kCGImagePropertyDNGActiveArea as String: [0, 0, 10001, 10000]]
        XCTAssertThrowsError(try AppleRAW.decodePlan(dng: huge, nativeSize: CGSize(width: 10000, height: 10001), mode: .preview))
        let plan = try AppleRAW.decodePlan(dng: fullCrop, nativeSize: extent.size, mode: .preview)
        XCTAssertThrowsError(try plan.outputDimensions(CGRect(x: 0, y: 0, width: 720.5, height: 640), availableMemory: .max))
    }

    func testFullExportRequiresNativeDecodeWithinSeparateCap() throws {
        XCTAssertNoThrow(try AppleRAW.validateFullExport(width: 6000, height: 4000))
        XCTAssertThrowsError(try AppleRAW.validateFullExport(width: 9504, height: 6336))
        XCTAssertThrowsError(try AppleRAW.validateFullExport(width: Int.max, height: Int.max))
        XCTAssertThrowsError(try AppleRAW.validateFullExport(width: 1, height: 0))
        let plan = try AppleRAW.decodePlan(dng: fullCrop, nativeSize: extent.size, mode: .full)
        XCTAssertEqual(plan.scale, 1)
        XCTAssertThrowsError(try plan.outputDimensions(CGRect(x: 0, y: 0, width: 360, height: 320), availableMemory: .max))
    }

    func testExportReopenMustMatchPreviewAndNeverUseProxy() throws {
        let preview: [String: Any] = ["sourceRevision": "hash", "decoderIdentity": "apple-raw-v1:test",
                                     "width": 6000, "height": 4000, "isProxy": true]
        var full = preview
        full["isProxy"] = false
        XCTAssertNoThrow(try EngineWorker.validateExportSource(preview: preview, full: full))
        let changes: [(String, Any)] = [("sourceRevision", "changed"), ("decoderIdentity", "changed"),
            ("width", 3000), ("height", 2000), ("isProxy", true)]
        for (key, value) in changes {
            var changed = full
            changed[key] = value
            XCTAssertThrowsError(try EngineWorker.validateExportSource(preview: preview, full: changed), key)
        }
        XCTAssertFalse(EngineWorker.canReuseSession(current: nil, requested: .preview, reuseAnyMode: true))
        XCTAssertFalse(EngineWorker.canReuseSession(current: .preview, requested: .full, reuseAnyMode: false))
        XCTAssertFalse(EngineWorker.canReuseSession(current: .full, requested: .preview, reuseAnyMode: false))
        XCTAssertTrue(EngineWorker.canReuseSession(current: .preview, requested: .preview, reuseAnyMode: false))
        XCTAssertTrue(EngineWorker.canReuseSession(current: .full, requested: .preview, reuseAnyMode: true))
    }

    func testStoredSensorCapCannotBeHiddenBySmallActiveArea() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try tiffFixture(rawCrop: false, rawUserCrop: false, storedWidth: 20000, storedHeight: 20000).write(to: url)
        XCTAssertThrowsError(try AppleRAW.sourceGeometry(url, checkCancellation: {}))
    }

    func testFullExportCapabilityUsesStoredSensorAndLogicalCrop() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let cases: [(UInt32, Bool)] = [(5000, false), (4000, true)]
        for (storedHeight, expected) in cases {
            try tiffFixture(rawCrop: false, rawUserCrop: false, storedWidth: 5000, storedHeight: storedHeight,
                activeWidth: 5000, activeHeight: 4000).write(to: url)
            let source = try AppleRAW.sourceGeometry(url, checkCancellation: {})
            let plan = try AppleRAW.decodePlan(dng: source.dng, nativeSize: CGSize(width: 5000, height: 4000), mode: .preview)
            XCTAssertEqual(source.canExportFullResolution(width: plan.width, height: plan.height), expected)
            XCTAssertFalse(source.canExportFullResolution(width: 6000, height: 5000))
        }
    }

    func testFullDecodeCapsStoredSensorEvenWhenCropIsSmall() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try tiffFixture(rawCrop: false, rawUserCrop: false, storedWidth: 6000, storedHeight: 4001).write(to: url)
        let source = try AppleRAW.sourceGeometry(url, checkCancellation: {})
        XCTAssertEqual(source.storedWidth, 6000)
        XCTAssertEqual(source.storedHeight, 4001)
        XCTAssertNoThrow(try AppleRAW.decodePlan(dng: source.dng, nativeSize: CGSize(width: 960, height: 800), mode: .preview))
        XCTAssertThrowsError(try AppleRAW.decode(url: url, availableMemory: .max, mode: .full, checkCancellation: {})) { error in
            XCTAssertTrue(error.localizedDescription.contains("above 24 megapixels"))
        }
    }

    func testDefaultCropMustBeIntegralAndInsideRelativeActiveBounds() throws {
        var dng = fullCrop
        dng[kCGImagePropertyDNGDefaultCropOrigin as String] = [120, 80]
        dng[kCGImagePropertyDNGDefaultCropSize as String] = [600, 560]
        let cropExtent = CGRect(x: 0, y: 0, width: 600, height: 560)
        XCTAssertNoThrow(try AppleRAW.dimensions(dng: dng, extent: cropExtent, availableMemory: .max))
        for (key, value) in [
            (kCGImagePropertyDNGDefaultCropOrigin as String, [121.0, 80]),
            (kCGImagePropertyDNGDefaultCropOrigin as String, [-1.0, 80]),
            (kCGImagePropertyDNGDefaultCropOrigin as String, [119.5, 80]),
            (kCGImagePropertyDNGDefaultCropSize as String, [599.5, 560]),
            (kCGImagePropertyDNGDefaultCropSize as String, [600.0, 0]),
            (kCGImagePropertyDNGDefaultCropSize as String, [600.0, 561])
        ] {
            var invalid = dng
            invalid[key] = value
            XCTAssertThrowsError(try AppleRAW.dimensions(dng: invalid, extent: cropExtent, availableMemory: .max), key)
        }
        XCTAssertThrowsError(try AppleRAW.dimensions(dng: dng, extent: extent, availableMemory: .max))
    }

    func testImplicitActiveUsesRAWIFDAndCropIdentityIsStable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for (missingActive, cropped) in [(false, false), (false, true), (true, false), (true, true)] {
            try tiffFixture(rawCrop: cropped, rawUserCrop: false, missingActive: missingActive).write(to: url)
            let source = try AppleRAW.sourceGeometry(url, checkCancellation: {})
            let cropExtent = CGRect(x: 0, y: 0, width: cropped ? 480 : 960, height: cropped ? 400 : 800)
            let native = try AppleRAW.originalDimensions(dng: source.dng, extent: cropExtent)
            XCTAssertEqual(native.0, cropped ? 480 : 960)
            XCTAssertEqual(native.1, cropped ? 400 : 800)
            let oldIdentity = "apple-raw-v1:test:8.dng"
            let identity = AppleRAW.decoderIdentity(os: "test", version: "8.dng", usesDefaultCrop: source.usesDefaultCropIdentity)
            XCTAssertEqual(identity, oldIdentity + (missingActive || cropped ? ":default-crop-v1" : ""))
            XCTAssertEqual(source.usesDefaultCropIdentity, missingActive || cropped)
            for mode in [AppleRAW.DecodeMode.preview, .full] {
                XCTAssertNoThrow(try AppleRAW.decodePlan(dng: source.dng, nativeSize: cropExtent.size, mode: mode))
            }
        }
        for fractionalTag: UInt16 in [50719, 50720] {
            try tiffFixture(rawCrop: true, rawUserCrop: false, fractionalTag: fractionalTag).write(to: url)
            let source = try AppleRAW.sourceGeometry(url, checkCancellation: {})
            XCTAssertThrowsError(try AppleRAW.originalDimensions(dng: source.dng,
                extent: CGRect(x: 0, y: 0, width: 480, height: 400)))
        }
        try tiffFixture(rawCrop: false, rawUserCrop: false, conflictingRAW: true).write(to: url)
        XCTAssertThrowsError(try AppleRAW.sourceGeometry(url, checkCancellation: {}))
        try tiffFixture(rawCrop: false, rawUserCrop: false, storedWidth: 800).write(to: url)
        XCTAssertThrowsError(try AppleRAW.sourceGeometry(url, checkCancellation: {}))
    }

    private func tiffFixture(rawCrop: Bool, rawUserCrop: Bool, storedWidth: UInt32 = 960, storedHeight: UInt32 = 800,
                             missingActive: Bool = false, fractionalTag: UInt16? = nil, conflictingRAW: Bool = false,
                             activeWidth: UInt32 = 960, activeHeight: UInt32 = 800) -> Data {
        func uint(_ value: UInt32, bytes: Int) -> Data {
            Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        typealias Tags = [UInt16: (UInt16, [UInt32])]
        func directory(_ tags: Tags, offset: Int) -> Data {
            var entries = uint(UInt32(tags.count), bytes: 2)
            var extra = Data()
            for tag in tags.keys.sorted() {
                let (type, values) = tags[tag]!
                let bytes = type == 1 ? 1 : type == 3 ? 2 : 4
                var payload = Data()
                for value in values {
                    payload.append(uint(value, bytes: bytes))
                    if type == 5 { payload.append(uint(tag == fractionalTag ? 7 : 1, bytes: 4)) }
                }
                entries.append(uint(UInt32(tag), bytes: 2))
                entries.append(uint(UInt32(type), bytes: 2))
                entries.append(uint(UInt32(values.count), bytes: 4))
                if payload.count <= 4 {
                    entries.append(payload)
                    entries.append(Data(repeating: 0, count: 4 - payload.count))
                } else {
                    entries.append(uint(UInt32(offset + 2 + tags.count * 12 + 4 + extra.count), bytes: 4))
                    extra.append(payload)
                }
            }
            entries.append(uint(0, bytes: 4))
            entries.append(extra)
            return entries
        }
        var root: Tags = [256: (4, [480]), 257: (4, [400]), 262: (3, [2]), 330: (4, [0]),
            50706: (1, [1, 4, 0, 0]), 50829: (4, [0, 0, 400, 480]),
            50719: (4, [0, 0]), 50720: (4, [480, 400]), 51125: (5, [0, 0, 1, 1])]
        if conflictingRAW { root[262] = (3, [32803]) }
        let rawOffset = 8 + directory(root, offset: 8).count
        root[330] = (4, [UInt32(rawOffset)])
        var raw: Tags = [254: (4, [0]), 256: (4, [storedWidth]), 257: (4, [storedHeight]), 262: (3, [34892]),
            50829: (4, [0, 0, activeHeight, activeWidth]), 50719: (4, rawCrop ? [120, 80] : [0, 0]),
            50720: (4, rawCrop ? [480, 400] : [activeWidth, activeHeight]), 51125: (5, rawUserCrop ? [1, 0, 1, 1] : [0, 0, 1, 1])]
        if missingActive { raw.removeValue(forKey: 50829) }
        if let fractionalTag, let field = raw[fractionalTag] { raw[fractionalTag] = (5, field.1) }
        var data = Data([73, 73, 42, 0, 8, 0, 0, 0])
        data.append(directory(root, offset: 8))
        data.append(directory(raw, offset: rawOffset))
        return data
    }
}
