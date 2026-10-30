import XCTest
import ImageIO
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
            if cropped || userCrop {
                XCTAssertThrowsError(try AppleRAW.dimensions(dng: source.dng, extent: extent, availableMemory: .max))
            } else {
                XCTAssertNoThrow(try AppleRAW.dimensions(dng: source.dng, extent: extent, availableMemory: .max))
            }
        }
        var malformed = tiffFixture(rawCrop: false, rawUserCrop: false)
        malformed.replaceSubrange(4..<8, with: [255, 255, 255, 255])
        try malformed.write(to: url)
        XCTAssertThrowsError(try AppleRAW.sourceGeometry(url, checkCancellation: {}))
        try Data([73, 73, 42]).write(to: url)
        XCTAssertThrowsError(try AppleRAW.sourceGeometry(url, checkCancellation: {}))
    }

    private func tiffFixture(rawCrop: Bool, rawUserCrop: Bool) -> Data {
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
                    if type == 5 { payload.append(uint(1, bytes: 4)) }
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
        let rawOffset = 8 + directory(root, offset: 8).count
        root[330] = (4, [UInt32(rawOffset)])
        let raw: Tags = [254: (4, [0]), 256: (4, [960]), 257: (4, [800]), 262: (3, [34892]),
            50829: (4, [0, 0, 800, 960]), 50719: (4, rawCrop ? [120, 80] : [0, 0]),
            50720: (4, rawCrop ? [480, 400] : [960, 800]), 51125: (5, rawUserCrop ? [1, 0, 1, 1] : [0, 0, 1, 1])]
        var data = Data([73, 73, 42, 0, 8, 0, 0, 0])
        data.append(directory(root, offset: 8))
        data.append(directory(raw, offset: rawOffset))
        return data
    }
}
