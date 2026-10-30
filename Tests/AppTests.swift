import XCTest
@testable import X3FuseNative

final class AppTests: XCTestCase {
    func testViewportPreservesEditsAndResetsWhenSourceChanges() {
        var viewport = ViewportTransform()
        let source = UUID()
        viewport.select(source)
        let start = viewport
        viewport.zoom(from: start, scale: 2, startAnchor: CGPoint(x: 20, y: 10), anchor: CGPoint(x: 20, y: 10))
        XCTAssertEqual(viewport.zoom, 2)
        XCTAssertEqual(viewport.offset, CGPoint(x: -20, y: -10))
        viewport.select(source)
        XCTAssertEqual(viewport.zoom, 2)
        viewport.offset = CGPoint(x: 500, y: -500)
        viewport.clamp(imageSize: CGSize(width: 100, height: 100), viewSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(viewport.offset, CGPoint(x: 50, y: -50))
        viewport.select(UUID())
        XCTAssertEqual(viewport.zoom, 1)
        XCTAssertEqual(viewport.offset, .zero)
    }

    @MainActor
    func testEditsDuringOpenCoalesceWithoutCancellingPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let asset = ImportedAsset(id: UUID(), name: "photo.x3f", sourceName: "source.x3f", importedAt: Date())
        try FileManager.default.createDirectory(at: root.appendingPathComponent(asset.id.uuidString), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = HeldEngine()
        let model = AppModel(library: AssetLibrary(store: AssetStore(root: root)), worker: engine)
        model.assets = [asset]
        model.select(asset.id)
        try await waitUntil { engine.renderedSettings.count == 1 }
        let cancelCount = engine.cancelCount
        for value in 1...10 { model.changeSettings { $0.exposure = Double(value) / 10 } }
        XCTAssertEqual(engine.cancelCount, cancelCount)
        XCTAssertEqual(engine.renderedSettings.count, 1)
        engine.completeRender()
        try await waitUntil { engine.renderedSettings.count == 2 }
        XCTAssertNil(model.frame, "An obsolete frame must not be displayed.")
        XCTAssertEqual(engine.renderedSettings.last?.exposure, 1)
        engine.completeRender()
        try await waitUntil { model.frame != nil }
        XCTAssertEqual(engine.renderedSettings.count, 2)
        model.enterBackground()
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    func testSaveFlushWaitsAndNewestEditIsWrittenLast() async throws {
        let queue = EditSaveQueue()
        let asset = ImportedAsset(id: UUID(), name: "photo.x3f", sourceName: "source.x3f", importedAt: Date())
        queue.pending[asset.id] = (asset, EditSettings(exposure: 1))
        var writes: [Double] = []
        var gate: CheckedContinuation<Void, Never>?
        let saving = Task {
            await queue.save(using: { settings, _ in
                writes.append(settings.exposure)
                if writes.count == 1 { await withCheckedContinuation { gate = $0 } }
            }, onError: { error, _ in XCTFail(error.localizedDescription) })
        }
        try await waitUntil { gate != nil }
        queue.pending[asset.id] = (asset, EditSettings(exposure: 2))
        var flushFinished = false
        let flush = Task {
            await queue.save(using: { _, _ in XCTFail("The existing save loop must own the writes.") },
                             onError: { error, _ in XCTFail(error.localizedDescription) })
            flushFinished = true
        }
        await Task.yield()
        XCTAssertFalse(flushFinished)
        gate?.resume()
        await saving.value
        await flush.value
        XCTAssertEqual(writes, [1, 2])
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertTrue(flushFinished)
    }

    @MainActor
    private func waitUntil(_ ready: () -> Bool) async throws {
        for _ in 0..<200 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The asynchronous operation did not reach the expected state.")
        throw CocoaError(.coderInvalidValue)
    }

    func testNewestRequestReplacesIntermediateEdits() {
        var requests = LatestRequest<Int>()
        requests.submit(1)
        let running = requests.take()!
        requests.submit(2)
        requests.submit(3)
        XCTAssertNotEqual(running.0, requests.revision)
        XCTAssertEqual(requests.take()?.1, 3)
        XCTAssertNil(requests.take())
        requests.submit(4)
        requests.cancel()
        XCTAssertNil(requests.take())
    }

    func testImportKeepsSameNameFilesSeparateAndRejectsDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.X3F")
        try Data([1, 2, 3]).write(to: source)
        let store = AssetStore(root: root.appendingPathComponent("Assets"))
        let first = try store.importFile(source)
        try Data([4, 5, 6]).write(to: source)
        let second = try store.importFile(source)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try Data(contentsOf: first.sourceURL(in: store.root)), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second.sourceURL(in: store.root)), Data([4, 5, 6]))
        XCTAssertEqual(try store.list().count, 2)
        let directory = root.appendingPathComponent("directory.x3f")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.importFile(directory))
        XCTAssertEqual(try store.list().count, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".import-") })
    }

    func testRecipePreservesCameraWhiteBalanceByDefault() throws {
        let data = Data(try EditSettings().recipeJSON(defaults: ["seed": 1234, "cameraProfile": "Standard"]).utf8)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(json["temperature"] is NSNull)
        XCTAssertTrue(json["film"] is NSNull)
        XCTAssertEqual(json["exposure"] as? Double, 0)
        XCTAssertEqual(json["seed"] as? Int, 1234)
        XCTAssertEqual(json["cameraProfile"] as? String, "Standard")
    }

    func testEditsPersistAndUnknownVersionsAreNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.x3f")
        try Data([1]).write(to: source)
        let store = AssetStore(root: root.appendingPathComponent("Assets"))
        let asset = try store.importFile(source)
        let settings = EditSettings(exposure: 1.5, temperature: 5500, tint: 10)
        try store.saveEdits(settings, for: asset)
        XCTAssertEqual(try store.loadEdits(for: asset), settings)
        let path = store.root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("native-edits.json")
        let newer = Data("{\"version\":99}".utf8)
        try newer.write(to: path)
        XCTAssertThrowsError(try store.saveEdits(EditSettings(), for: asset))
        XCTAssertEqual(try Data(contentsOf: path), newer)
        let invalid = Data("not valid JSON".utf8)
        try invalid.write(to: path)
        XCTAssertThrowsError(try store.saveEdits(EditSettings(), for: asset))
        XCTAssertEqual(try Data(contentsOf: path), invalid)
    }
}

private final class HeldEngine: ImageEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: [EditSettings] = []
    private var cancellations = 0
    private var completion: CheckedContinuation<PreviewResult, Error>?
    var renderedSettings: [EditSettings] { lock.withLock { settings } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func render(asset: ImportedAsset, settings: EditSettings) async throws -> PreviewResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                self.settings.append(settings)
                completion = continuation
            }
        }
    }

    func completeRender() {
        let continuation = lock.withLock {
            defer { completion = nil }
            return completion
        }
        continuation?.resume(returning: PreviewResult(frame: PixelFrame(width: 1, height: 1, bytesPerRow: 4, pixels: Data([0, 0, 0, 255])),
                                                     prepareMilliseconds: 1, renderMilliseconds: 1, asShotTemperature: 6500,
                                                     sourceRevision: "test", renderVersion: 1))
    }

    func export(asset: ImportedAsset, settings: EditSettings) async throws -> ExportResult { throw CancellationError() }
    func cancel() { lock.withLock { cancellations += 1 } }
    func setActive(_ active: Bool) { if !active { cancel() } }
    func releaseSession() { cancel() }
}
