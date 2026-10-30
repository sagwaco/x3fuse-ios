import XCTest
@testable import X3FuseNative

final class AppTests: XCTestCase {
    @MainActor
    func testDisablingDNGMonochromeFilmKeepsRecipeValidAndIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let asset = ImportedAsset(id: UUID(), name: "photo.dng", sourceName: "source.dng", importedAt: Date())
        try FileManager.default.createDirectory(at: root.appendingPathComponent(asset.id.uuidString), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = HeldEngine()
        let model = AppModel(library: AssetLibrary(store: AssetStore(root: root)), worker: engine)
        model.assets = [asset]
        model.select(asset.id)
        try await waitUntil { engine.renderedSettings.count == 1 }
        engine.completeRender()
        try await waitUntil { model.frame != nil && !model.isRendering }
        model.selectFilm(20)
        try await waitUntil { !model.isApplyingLook && model.settings.filmStock == 20 }
        XCTAssertNotEqual(model.settings.fields["monochrome"], .null)
        model.setFilmEnabled(false)
        XCTAssertNil(model.settings.film)
        XCTAssertEqual(model.settings.fields["monochrome"], .null)
        let identity = try XCTUnwrap(model.currentEdits?.decoderIdentity)
        XCTAssertEqual(model.currentEdits?.document.version, 3)
        XCTAssertEqual(model.currentEdits?.document.decoderIdentity, identity)
        let canonical = try await engine.normalize(model.settings)
        let document = RecipeDocument(version: 3, sourceRevision: "test", recipe: canonical, decoderIdentity: identity)
        _ = try await engine.validateDocument(asset: asset, json: document.json, previous: nil)
        model.enterBackground()
        try await waitUntil { (try? AssetStore(root: root).loadEdits(for: asset).data) != nil }
        guard case .current(let saved) = try AssetStore(root: root).loadEdits(for: asset).content else { return XCTFail("Missing DNG edits.") }
        XCTAssertNil(saved.document.recipe.film)
        XCTAssertEqual(saved.document.recipe.fields["monochrome"], .null)
        XCTAssertNoThrow(try saved.validateDecoder(identity))
        engine.completeRender()
    }

    @MainActor
    func testFilmOffOnPreservesSavedFilmExactly() async throws {
        try await assertFilmRestoration(afterCamera: false)
    }

    @MainActor
    func testCameraToFilmPreservesSavedFilmExactly() async throws {
        try await assertFilmRestoration(afterCamera: true)
    }

    @MainActor
    private func assertFilmRestoration(afterCamera: Bool) async throws {
        for stock in [2, 20] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let asset = ImportedAsset(id: UUID(), name: "photo.x3f", sourceName: "source.x3f", importedAt: Date())
            try FileManager.default.createDirectory(at: root.appendingPathComponent(asset.id.uuidString), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let engine = HeldEngine()
            let model = AppModel(library: AssetLibrary(store: AssetStore(root: root)), worker: engine)
            model.assets = [asset]; model.select(asset.id)
            try await waitUntil { engine.renderedSettings.count == 1 }
            engine.completeRender()
            try await waitUntil { model.frame != nil && !model.isRendering }
            let original = try await engine.normalize(EditSettings(canonicalJSON: """
            {"seed":4321,"exposure":1.2,"monochrome":{"filter":"red"},
             "film":{"film":\(stock),"paper":3,"negative":true,"evFilm":0.7,"evPaper":1.2,
                     "grainParams":{"rmsGranularity":[5,8,11],"blur":0.9},"couplersRadius":0.002},
             "effects":{"grain":false,"halation":false,"grainParams":{"rmsGranularity":[3,7,9]}}}
            """))
            model.changeSettings { $0 = original }
            try await waitUntil { engine.renderedSettings.count == 2 }
            if afterCamera {
                model.selectCameraProfile("Monochrome")
                try await waitUntil { !model.isApplyingLook }
                XCTAssertNil(model.settings.film)
                XCTAssertEqual(model.settings.fields["cameraProfile"], .string("Monochrome"))
            } else {
                model.setFilmEnabled(false)
                XCTAssertNil(model.settings.film)
            }
            model.setFilmEnabled(true)
            let restored = try await engine.normalize(model.settings)
            XCTAssertEqual(restored.film, original.film, "Restoring film must keep custom paper and direct scan settings.")
            XCTAssertEqual(restored.fields["cameraProfile"], .null)
            XCTAssertEqual(restored.fields["rawColor"] ?? .null, .null)
            XCTAssertEqual(restored.fields["monochrome"], stock == 20 ? .object(["filter": .string("red")]) : .null)
            for key in original.fields.keys where !["film", "cameraProfile", "rawColor", "monochrome"].contains(key) {
                XCTAssertEqual(restored.fields[key], original.fields[key], key)
            }
            engine.completeRender()
            try await waitUntil { engine.renderedSettings.count == 3 }
            engine.completeRender()
            try await waitUntil { !model.isRendering }
            model.enterBackground()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    func testSuspendedCameraLookCannotApplyAfterSourceReturnsToSameAsset() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let assets = ["a.x3f", "b.x3f"].map {
            ImportedAsset(id: UUID(), name: $0, sourceName: "source.x3f", importedAt: Date())
        }
        for asset in assets {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(asset.id.uuidString), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = HeldEngine(suspendLooks: true)
        let model = AppModel(library: AssetLibrary(store: AssetStore(root: root)), worker: engine)
        model.assets = assets; model.select(assets[0].id)
        try await waitUntil { engine.renderedSettings.count == 1 }
        engine.completeRender()
        try await waitUntil { model.frame != nil && !model.isRendering }
        model.selectCameraProfile("Monochrome")
        try await waitUntil { engine.isLookSuspended }
        for (index, asset) in [assets[1], assets[0]].enumerated() {
            model.select(asset.id)
            try await waitUntil { engine.renderedSettings.count == index + 2 }
            engine.completeRender()
            try await waitUntil { model.frame != nil && !model.isRendering }
        }
        let original = model.settings
        let revision = model.currentEdits?.document.revision
        engine.completeLook()
        try await waitUntil { !model.isApplyingLook }
        XCTAssertEqual(model.selectedID, assets[0].id)
        XCTAssertEqual(model.settings, original)
        XCTAssertEqual(model.currentEdits?.document.revision, revision)
        XCTAssertEqual(engine.renderedSettings.count, 3)
        model.enterBackground()
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    func testCameraMatchingValidatesAvailabilityAndDiscardsStaleChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let asset = ImportedAsset(id: UUID(), name: "photo.x3f", sourceName: "source.x3f", importedAt: Date())
        try FileManager.default.createDirectory(at: root.appendingPathComponent(asset.id.uuidString), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = HeldEngine()
        let model = AppModel(library: AssetLibrary(store: AssetStore(root: root)), worker: engine)
        model.assets = [asset]; model.select(asset.id)
        try await waitUntil { engine.renderedSettings.count == 1 }
        engine.completeRender()
        try await waitUntil { model.frame != nil && !model.isRendering }
        let original = model.settings
        model.selectCameraProfile("Unavailable")
        XCTAssertFalse(model.isApplyingLook)
        XCTAssertEqual(model.settings, original)
        model.selectCameraProfile("Monochrome")
        try await waitUntil { !model.isApplyingLook }
        XCTAssertEqual(model.settings.fields["cameraProfile"], .string("Monochrome"))
        XCTAssertEqual(model.settings.fields["monochrome"], .object(["filter": .string("neutral")]))
        XCTAssertEqual(model.settings.fields["seed"], original.fields["seed"])
        try await waitUntil { engine.renderedSettings.count == 2 }
        model.selectCameraProfile("Standard")
        model.changeSettings { $0.exposure = 0.5 }
        try await waitUntil { !model.isApplyingLook }
        XCTAssertEqual(model.settings.exposure, 0.5)
        XCTAssertEqual(model.settings.fields["cameraProfile"], .string("Monochrome"))
        engine.completeRender()
        try await waitUntil { engine.renderedSettings.count == 3 }
        engine.completeRender()
        try await waitUntil { !model.isRendering }
        model.enterBackground()
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    func testResetEditsClearsCanonicalColorAdjustments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let asset = ImportedAsset(id: UUID(), name: "photo.x3f", sourceName: "source.x3f", importedAt: Date())
        try FileManager.default.createDirectory(at: root.appendingPathComponent(asset.id.uuidString), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = HeldEngine()
        let model = AppModel(library: AssetLibrary(store: AssetStore(root: root)), worker: engine)
        model.assets = [asset]; model.select(asset.id)
        try await waitUntil { engine.renderedSettings.count == 1 }
        engine.completeRender()
        try await waitUntil { model.frame != nil && !model.isRendering }
        var recipe = model.settings
        var hsl = HSLDraft(recipe: recipe)
        hsl.bands[0].hue = 40; hsl.apply(to: &recipe)
        var grading = GradingDraft(recipe: recipe)
        grading.wheels[.shadows]?.setHue(120)
        grading.wheels[.shadows]?.setStrength(30)
        grading.apply(to: &recipe)
        let canonical = try await engine.normalize(recipe)
        model.changeSettings { $0 = canonical }
        try await waitUntil { engine.renderedSettings.count == 2 }
        model.resetEdits()
        let reset = try await engine.normalize(model.settings)
        XCTAssertEqual(reset.canonicalJSON, model.imageInfo?.defaultRecipe.canonicalJSON)
        XCTAssertNil(reset.fields["wheels"])
        engine.completeRender()
        try await waitUntil { engine.renderedSettings.count == 3 }
        engine.completeRender()
        try await waitUntil { !model.isRendering }
        model.enterBackground()
        try await Task.sleep(for: .milliseconds(30))
    }

    @MainActor
    func testDenoiseReleaseQueuesOnceAndOnlyNewDenoiseCancelsPreparation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let asset = ImportedAsset(id: UUID(), name: "photo.x3f", sourceName: "source.x3f", importedAt: Date())
        try FileManager.default.createDirectory(at: root.appendingPathComponent(asset.id.uuidString), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = HeldEngine()
        let model = AppModel(library: AssetLibrary(store: AssetStore(root: root)), worker: engine)
        model.assets = [asset]
        model.select(asset.id)
        try await waitUntil { engine.renderedSettings.count == 1 }
        engine.completeRender()
        try await waitUntil { model.frame != nil && !model.isRendering }
        var draft = DenoiseDraft(recipe: model.settings)
        for intensity in 1...5 { draft.value.intensity = Double(intensity) }
        XCTAssertEqual(engine.renderedSettings.count, 1)
        model.applyDenoise(try XCTUnwrap(draft.finishGesture()))
        try await waitUntil { engine.renderedSettings.count == 2 && model.isPreparingNoise }
        let cancellations = engine.cancelCount
        model.changeSettings { $0.exposure = 0.5 }
        XCTAssertEqual(engine.cancelCount, cancellations)
        draft.value.intensity = 3
        model.applyDenoise(try XCTUnwrap(draft.finishGesture()))
        XCTAssertEqual(engine.cancelCount, cancellations + 1)
        engine.completeRender()
        try await waitUntil { engine.renderedSettings.count == 3 }
        XCTAssertEqual(engine.renderedSettings.last?["denoise"], 3)
        engine.completeRender()
        try await waitUntil { !model.isRendering }
        model.enterBackground()
        try await Task.sleep(for: .milliseconds(30))
    }

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
        queue.pending[asset.id] = (asset, try snapshot(asset: asset, exposure: 1))
        var writes: [Double] = []
        var gate: CheckedContinuation<Void, Never>?
        let saving = Task {
            await queue.save(using: { settings, _ in
                writes.append(settings.document.recipe.exposure)
                if writes.count == 1 { await withCheckedContinuation { gate = $0 } }
            }, onError: { error, _ in XCTFail(error.localizedDescription) })
        }
        try await waitUntil { gate != nil }
        queue.pending[asset.id] = (asset, try snapshot(asset: asset, exposure: 2))
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
        try assertAtomicImport(fileExtension: "X3F")
    }

    func testDNGImportKeepsUniquePersistentCopiesAndOriginalUnchanged() throws {
        try assertAtomicImport(fileExtension: "DNG")
    }

    private func assertAtomicImport(fileExtension: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.\(fileExtension)")
        try Data([1, 2, 3]).write(to: source)
        let store = AssetStore(root: root.appendingPathComponent("Assets"))
        let first = try store.importFile(source)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        XCTAssertEqual(first.sourceName, "source.\(fileExtension.lowercased())")
        try Data([4, 5, 6]).write(to: source)
        let second = try store.importFile(source)
        XCTAssertEqual(try Data(contentsOf: source), Data([4, 5, 6]))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try Data(contentsOf: first.sourceURL(in: store.root)), Data([1, 2, 3]))
        XCTAssertEqual(try Data(contentsOf: second.sourceURL(in: store.root)), Data([4, 5, 6]))
        XCTAssertEqual(try store.list().count, 2)
        let directory = root.appendingPathComponent("directory.\(fileExtension)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.importFile(directory))
        XCTAssertEqual(try store.list().count, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.root.path).contains { $0.hasPrefix(".import-") })
    }

    func testCanonicalRecipeRoundTripPreservesIntegerFieldsAndUntouchedValues() async throws {
        let engine = EngineWorker()
        for seed in [UInt32(0), UInt32.max] {
            let input = """
            {"seed":\(seed),"rotation":1,"denoise":0,"whiteBalanceGains":[1.2,1,0.9],
             "film":{"film":2,"paper":3,"grain":false,"evFilm":0.5,"couplers":0.42},
             "crop":{"x":0.1,"y":0.1,"width":0.8,"height":0.8}}
            """
            let canonical = try await engine.normalize(EditSettings(canonicalJSON: input))
            var edited = canonical
            edited.exposure = 1.5
            edited["contrast"] = 12
            let normalized = try await engine.normalize(edited)
            XCTAssertEqual(normalized.fields["seed"], .integer(Int64(seed)))
            XCTAssertEqual(normalized.fields["rotation"], .integer(1))
            XCTAssertEqual(normalized.fields["denoise"], .integer(0))
            for field in ["film", "whiteBalanceGains", "crop", "curves", "hsl", "wheels", "seed"] {
                XCTAssertEqual(normalized.fields[field], canonical.fields[field], field)
            }
            let encoded = try JSONEncoder().encode(normalized)
            let restored = try JSONDecoder().decode(EditSettings.self, from: encoded)
            XCTAssertEqual(restored.canonicalJSON, normalized.canonicalJSON)
            let parsedAgain = try await engine.normalize(restored)
            XCTAssertEqual(parsedAgain.canonicalJSON, restored.canonicalJSON)
        }
    }

    func testSchemaOneMigrationUsesCameraDefaultsAndRunsOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.x3f")
        try Data([1]).write(to: source)
        let store = AssetStore(root: root.appendingPathComponent("Assets"))
        let asset = try store.importFile(source)
        let path = store.root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("native-edits.json")
        let legacyJSON = """
        {"version":1,"assetID":"\(asset.id)","settings":{"exposure":1.5,"temperature":5500,"tint":10}}
        """
        try Data(legacyJSON.utf8).write(to: path)
        let loaded = try store.loadEdits(for: asset)
        guard case .legacy(let legacy) = loaded.content else { return XCTFail("Expected schema one.") }
        let engine = EngineWorker()
        let camera = try await engine.normalize(EditSettings(canonicalJSON: """
        {"cameraProfile":"Standard","seed":1234,"sharpen":50,"film":null,
         "crop":{"x":0.1,"y":0.1,"width":0.8,"height":0.8}}
        """))
        let migrated = try await engine.normalize(legacy.applying(to: camera))
        XCTAssertEqual(migrated.fields["cameraProfile"], camera.fields["cameraProfile"])
        XCTAssertEqual(migrated.fields["crop"], camera.fields["crop"])
        XCTAssertEqual(migrated.fields["seed"], .integer(1234))
        XCTAssertEqual(migrated["sharpen"], 50)
        XCTAssertEqual(migrated.exposure, 1.5)
        XCTAssertEqual(migrated.temperature, 5500)
        XCTAssertNil(migrated.film)
        let document = RecipeDocument(sourceRevision: String(repeating: "a", count: 64), recipe: migrated)
        let saved = NativeEdits(assetID: asset.id, renderVersion: 20, document: document)
        _ = try store.saveEdits(saved, for: asset, replacing: loaded.data)
        guard case .current(let restored) = try store.loadEdits(for: asset).content else { return XCTFail("Migration must not run again.") }
        XCTAssertEqual(restored.document.recipe.canonicalJSON, migrated.canonicalJSON)
        XCTAssertEqual(restored.assetID, asset.id)
        XCTAssertEqual(try Data(contentsOf: asset.sourceURL(in: store.root)), Data([1]))
    }

    func testConfirmedOlderSidecarAdvancesBothHistories() async throws {
        let engine = EngineWorker()
        let localRecipe = try await engine.normalize(EditSettings(canonicalJSON: "{\"film\":null,\"seed\":10}"))
        let importedRecipe = try await engine.normalize(EditSettings(canonicalJSON: "{\"film\":{\"film\":3},\"seed\":99,\"exposure\":2}"))
        let local = RecipeDocument(sourceRevision: "same", revision: 25, updatedMs: 4_000_000_000_000, recipe: localRecipe)
        let imported = RecipeDocument(sourceRevision: "same", revision: 2, updatedMs: 3_000_000_000_000, recipe: importedRecipe)
        let replacement = try local.replacing(with: imported)
        XCTAssertEqual(replacement.revision, 26)
        XCTAssertEqual(replacement.updatedMs, 4_000_000_000_001)
        XCTAssertEqual(replacement.recipe.canonicalJSON, importedRecipe.canonicalJSON)
        var wrongSource = imported
        wrongSource.sourceRevision = "different"
        XCTAssertThrowsError(try local.replacing(with: wrongSource))
    }

    func testFilmStockChangeKeepsOtherFilmParameters() async throws {
        let engine = EngineWorker()
        let original = try await engine.normalize(EditSettings(canonicalJSON: "{\"film\":{\"film\":2,\"evFilm\":1.2,\"grain\":false,\"couplers\":0.42}}"))
        var edited = original
        var film = try XCTUnwrap(edited.film)
        film["film"] = .integer(4)
        edited.film = film
        let result = try await engine.normalize(edited)
        var expected = try XCTUnwrap(original.film)
        expected["film"] = .integer(4)
        XCTAssertEqual(result.film, expected)
    }

    func testEditsPersistAndExternalChangesAreNeverOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.x3f")
        try Data([1]).write(to: source)
        let store = AssetStore(root: root.appendingPathComponent("Assets"))
        let asset = try store.importFile(source)
        let saved = try snapshot(asset: asset, exposure: 1.5)
        let initial = try store.saveEdits(saved, for: asset, replacing: nil)
        guard case .current(let restored) = try store.loadEdits(for: asset).content else { return XCTFail("Missing full recipe.") }
        XCTAssertEqual(restored, saved)
        let path = store.root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("native-edits.json")
        let newer = Data("{\"version\":99,\"assetID\":\"\(asset.id)\"}".utf8)
        try newer.write(to: path)
        XCTAssertThrowsError(try store.saveEdits(saved, for: asset, replacing: initial))
        XCTAssertEqual(try Data(contentsOf: path), newer)
        let invalid = Data("not valid JSON".utf8)
        try invalid.write(to: path)
        XCTAssertThrowsError(try store.saveEdits(saved, for: asset, replacing: initial))
        XCTAssertEqual(try Data(contentsOf: path), invalid)
        try initial.write(to: path)
        let external = try snapshot(asset: asset, exposure: 3)
        let changed = try store.saveEdits(external, for: asset, replacing: initial)
        XCTAssertThrowsError(try store.saveEdits(saved, for: asset, replacing: initial))
        XCTAssertEqual(try Data(contentsOf: path), changed)
    }

    func testRecipeReadRejectsOversizedFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 32, count: 1_048_577).write(to: file)
        XCTAssertThrowsError(try AssetStore.readBounded(file))
    }

    private func snapshot(asset: ImportedAsset, exposure: Double) throws -> NativeEdits {
        let recipe = try EditSettings(canonicalJSON: "{\"exposure\":\(exposure),\"film\":null,\"seed\":1234}")
        return NativeEdits(assetID: asset.id, renderVersion: 20, document: RecipeDocument(sourceRevision: "test", recipe: recipe))
    }

}

private final class HeldEngine: ImageEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var settings: [EditSettings] = []
    private var cancellations = 0
    private var completion: CheckedContinuation<PreviewResult, Error>?
    private let suspendLooks: Bool
    private var lookCompletion: CheckedContinuation<Void, Never>?
    var isLookSuspended: Bool { lock.withLock { lookCompletion != nil } }

    init(suspendLooks: Bool = false) { self.suspendLooks = suspendLooks }

    func completeLook() {
        let continuation = lock.withLock {
            defer { lookCompletion = nil }
            return lookCompletion
        }
        continuation?.resume()
    }
    var renderedSettings: [EditSettings] { lock.withLock { settings } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func prepare(asset: ImportedAsset) async throws -> ImageInfo {
        let defaults = try await normalize(EditSettings(canonicalJSON: "{\"film\":null,\"seed\":1234}"))
        return ImageInfo(width: 1200, height: 800, sourceRevision: "test", renderVersion: 1, defaultRecipe: defaults, asShotTemperature: 6500,
                         catalog: FilmCatalog(films: [
                            FilmStock(index: 2, key: "kodak_portra_400", name: "Kodak Portra 400", monochrome: false),
                            FilmStock(index: 20, key: "kodak_doublex", name: "Kodak Double-X 5222", monochrome: true)
                         ], defaultFilm: [:]), prepareMilliseconds: 1,
                         cameraProfiles: [CameraProfile(id: "Standard", name: "Standard"), CameraProfile(id: "Monochrome", name: "Monochrome")],
                         decoderIdentity: asset.isDNG ? "apple-raw-v1:test_OS_build:8.dng" : nil)
    }
    func normalize(_ settings: EditSettings) async throws -> EditSettings { try await EngineWorker().normalize(settings) }
    func applyLook(_ id: String, to settings: EditSettings) async throws -> EditSettings {
        let applied = try await EngineWorker().applyLook(id, to: settings)
        if suspendLooks {
            await withCheckedContinuation { continuation in
                lock.withLock { lookCompletion = continuation }
            }
        }
        return applied
    }
    func validateDocument(asset: ImportedAsset, json: String, previous: RecipeDocument?) async throws -> RecipeDocument {
        let values = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let recipe = String(decoding: try JSONSerialization.data(withJSONObject: values["recipe"]!), as: UTF8.self)
        let normalized = try await normalize(EditSettings(canonicalJSON: recipe))
        if asset.isDNG, normalized.film == nil, normalized.fields["monochrome"] != nil, normalized.fields["monochrome"] != .null {
            throw EditStorageError("A DNG cannot retain a sensor filter without monochrome film.")
        }
        return RecipeDocument(version: asset.isDNG ? 3 : 2, sourceRevision: "test", recipe: normalized,
                              decoderIdentity: asset.isDNG ? "apple-raw-v1:test_OS_build:8.dng" : nil)
    }
    func exportSidecar(asset: ImportedAsset, document: RecipeDocument) async throws -> URL { throw CancellationError() }

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
                                                     sourceRevision: "test", renderVersion: 1, recipe: renderedSettings.last ?? EditSettings()))
    }

    func export(asset: ImportedAsset, settings: EditSettings, format: ExportFormat) async throws -> ExportResult { throw CancellationError() }
    func cancel() { lock.withLock { cancellations += 1 } }
    func setActive(_ active: Bool) { if !active { cancel() } }
    func releaseSession() { cancel() }
}
