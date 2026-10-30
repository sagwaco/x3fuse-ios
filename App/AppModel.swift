import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var assets: [ImportedAsset] = []
    @Published var selectedID: UUID?
    @Published var settings = EditSettings()
    @Published var frame: PixelFrame?
    @Published var isRendering = false
    @Published var isImporting = false
    @Published var isExporting = false
    @Published var isBenchmarking = false
    @Published var message: String?
    @Published var exportURL: URL?
    @Published var status = "Import an X3F, X3I, or DNG image to begin."
    @Published var asShotTemperature = 6500.0
    @Published private(set) var imageInfo: ImageInfo?
    @Published private(set) var currentEdits: NativeEdits?
    @Published private(set) var isApplyingLook = false
    @Published var isTransferringRecipe = false
    @Published var cropSession: CropSession?
    @Published private(set) var isCropping = false
    @Published private(set) var isPreparingNoise = false
    private var preparedNoise: DenoiseSettings?
    private var renderingNoise: DenoiseSettings?
    private var selectionRevision: UInt64 = 0
    private var disabledFilm: [String: JSONValue]?
    private var benchmarkCancellationEvents: [String] = []

    let library: AssetLibrary
    let worker: any ImageEngine
    private var requests = LatestRequest<(ImportedAsset, EditSettings)>()
    private var pumping = false
    private var active = true
    private var loaded = false
    @Published private(set) var selectionLoading = false
    private var saveTask: Task<Void, Never>?
    private let edits = EditSaveQueue()
    private var saveErrors = Set<UUID>()

    init(library: AssetLibrary = AssetLibrary(), worker: any ImageEngine = EngineWorker()) {
        self.library = library
        self.worker = worker
    }

    var selectedAsset: ImportedAsset? { assets.first { $0.id == selectedID } }

    func start() async {
        guard !loaded else { return }
        loaded = true
        do {
            assets = try await library.list()
            try await library.prepareDocuments()
            if ProcessInfo.processInfo.arguments.contains("--benchmark") {
                await runBenchmark()
            } else if let first = assets.first {
                select(first.id)
            }
        } catch { message = error.localizedDescription }
    }

    func select(_ id: UUID?) {
        guard selectedID != id || frame == nil else { return }
        flushEdits()
        selectedID = id
        selectionRevision &+= 1
        let selection = selectionRevision
        frame = nil
        exportURL = nil
        settings = EditSettings()
        imageInfo = nil
        currentEdits = nil
        disabledFilm = nil
        preparedNoise = nil
        requests.cancel()
        worker.cancel()
        guard let asset = selectedAsset else { return }
        selectionLoading = true
        status = "Opening \(asset.name)…"
        Task {
            defer { if selectionRevision == selection { selectionLoading = false } }
            do {
                await savePendingEdits()
                let loaded = try await library.loadEdits(asset)
                let metadata = try await worker.prepare(asset: asset)
                var document: RecipeDocument
                switch loaded.content {
                case .empty:
                    document = RecipeDocument(version: metadata.decoderIdentity == nil ? 2 : 3,
                        sourceRevision: metadata.sourceRevision, recipe: metadata.defaultRecipe, decoderIdentity: metadata.decoderIdentity)
                case .legacy(let legacy):
                    guard metadata.decoderIdentity == nil else { throw EditStorageError("Legacy DNG edits cannot be opened by Apple RAW. The file was kept unchanged.") }
                    document = RecipeDocument(sourceRevision: metadata.sourceRevision, recipe: legacy.applying(to: metadata.defaultRecipe))
                case .current(let saved):
                    try saved.validateDecoder(metadata.decoderIdentity)
                    document = saved.document
                }
                document = edits.pending[asset.id]?.1.document ?? document
                document.recipe = try await worker.normalize(document.recipe)
                let validated = try await worker.validateDocument(asset: asset, json: document.json, previous: nil)
                guard selectionRevision == selection, selectedID == asset.id else { return }
                let snapshot = NativeEdits(assetID: asset.id, renderVersion: metadata.renderVersion, document: validated,
                                           decoderIdentity: metadata.decoderIdentity)
                try await library.acceptEdits(snapshot, asset: asset, replacing: loaded.data, persist: loaded.data != nil)
                guard selectionRevision == selection else { return }
                imageInfo = metadata
                preparedNoise = DenoiseSettings(recipe: metadata.defaultRecipe)
                asShotTemperature = metadata.asShotTemperature
                currentEdits = snapshot
                settings = validated.recipe
                selectionLoading = false
                requestPreview()
            } catch is CancellationError {
                status = "Opening paused. Tap Reload to continue."
            } catch {
                guard selectionRevision == selection else { return }
                status = "Could not open the saved recipe. Existing edits are unchanged."
                message = error.localizedDescription
            }
        }
    }

    func changeSettings(_ update: (inout EditSettings) -> Void) {
        guard let asset = selectedAsset, !selectionLoading, var snapshot = currentEdits else { return }
        update(&settings)
        snapshot.document.setRecipe(settings)
        currentEdits = snapshot
        edits.pending[asset.id] = (asset, snapshot)
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)) }
            catch { return }
            await savePendingEdits()
        }
        requestPreview()
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value {
            flushEdits()
            requests.cancel()
            if !isExporting && !isBenchmarking { worker.setActive(false) }
            status = "Paused while the app is inactive."
        } else {
            worker.setActive(true)
            if !isBenchmarking {
                if currentEdits == nil, selectedID != nil { select(selectedID) }
                else { requestPreview() }
            }
        }
    }

    func enterBackground() {
        if isBenchmarking { benchmarkCancellationEvents.append("background") }
        setActive(false)
        flushEdits()
        requests.cancel()
        worker.setActive(false)
    }

    func memoryWarning() {
        if isBenchmarking { benchmarkCancellationEvents.append("memoryWarning") }
        requests.cancel()
        worker.releaseSession()
        frame = nil
        status = "Image memory released. Tap Reload to continue."
    }

    func requestPreview() {
        guard let asset = selectedAsset, !selectionLoading, currentEdits != nil else { return }
        requests.submit((asset, settings))
        guard active, !isExporting, !isBenchmarking, !isTransferringRecipe, !isCropping else { return }
        guard !pumping else { return }
        pumping = true
        Task { await drainPreviews() }
    }

    private func drainPreviews() async {
        isRendering = true
        defer { pumping = false; isRendering = false; isPreparingNoise = false; renderingNoise = nil }
        while active, !isExporting, !isBenchmarking, !isTransferringRecipe, !isCropping, let (revision, request) = requests.take() {
            renderingNoise = DenoiseSettings(recipe: request.1)
            isPreparingNoise = renderingNoise != preparedNoise
            status = isPreparingNoise ? "Applying noise reduction…" : "Rendering…"
            do {
                let result = try await worker.render(asset: request.0, settings: request.1)
                if selectedID == request.0.id { preparedNoise = DenoiseSettings(recipe: result.recipe) }
                guard active, requests.revision == revision, selectedID == request.0.id else { continue }
                frame = result.frame
                settings = result.recipe
                currentEdits?.document.recipe = result.recipe
                asShotTemperature = result.asShotTemperature
                status = "\(result.frame.width) × \(result.frame.height) preview · \(Int(result.renderMilliseconds)) ms render"
            } catch is CancellationError {
                if isPreparingNoise { preparedNoise = nil }
                continue
            } catch {
                guard active, requests.revision == revision, selectedID == request.0.id else { continue }
                status = "Could not render this image."
                message = error.localizedDescription
            }
        }
    }

    func importFiles(_ urls: [URL]) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            var first: UUID?
            var failures: [String] = []
            for url in urls {
                do {
                    let interval = AppMetrics.signposter.beginInterval("Import")
                    defer { AppMetrics.signposter.endInterval("Import", interval) }
                    let asset = try await library.importFile(url)
                    assets.insert(asset, at: 0)
                    first = first ?? asset.id
                } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            if let first { select(first) }
            if !failures.isEmpty { message = failures.joined(separator: "\n") }
        }
    }

    func export(_ format: ExportFormat = .jpeg) {
        guard let asset = selectedAsset, currentEdits != nil, !isExporting, active else { return }
        let snapshot = settings
        flushEdits()
        requests.cancel()
        worker.cancel()
        isExporting = true
        exportURL = nil
        status = "Exporting \(format.title)…"
        Task {
            do {
                let result = try await worker.export(asset: asset, settings: snapshot, format: format)
                exportURL = result.url
                status = "Saved \(format.title) to Documents/Exports."
                if !result.warnings.isEmpty { message = result.warnings.joined(separator: "\n") }
            } catch is CancellationError {
                status = "Export cancelled."
            } catch { message = error.localizedDescription; status = "Export failed." }
            isExporting = false
            if active { requestPreview() }
        }
    }

    func resetEdits() {
        guard let defaults = imageInfo?.defaultRecipe else { return }
        disabledFilm = nil
        changeSettings { $0 = defaults }
    }

    func rotate(_ quarterTurns: Int) {
        changeSettings { recipe in
            recipe.fields["rotation"] = .integer(Int64((Int(recipe["rotation"]) + quarterTurns + 4) % 4))
        }
    }

    func beginCrop() {
        guard let asset = selectedAsset, let info = imageInfo, !isCropping else { return }
        requests.cancel()
        worker.cancel()
        isCropping = true
        cropSession = CropSession(asset: asset, recipe: settings, cameraCrop: CropRect(recipe: info.defaultRecipe),
                                  imageSize: CGSize(width: info.width, height: info.height))
    }

    func cropPreview(_ session: CropSession) async throws -> PixelFrame {
        guard selectedID == session.asset.id, isCropping else { throw CancellationError() }
        return try await worker.render(asset: session.asset, settings: session.previewRecipe).frame
    }

    func applyCrop(_ crop: CropRect, session: CropSession) {
        guard selectedID == session.asset.id else { return }
        changeSettings { $0.fields["crop"] = crop.json }
    }

    func endCrop() {
        worker.cancel()
        isCropping = false
        cropSession = nil
        if active { requestPreview() }
    }

    func applyDenoise(_ noise: DenoiseSettings) {
        guard selectedAsset?.isDNG != true else { return }
        if isPreparingNoise, renderingNoise != noise { worker.cancel() }
        changeSettings { noise.apply(to: &$0) }
    }

    func setFilmEnabled(_ enabled: Bool) {
        if enabled {
            guard let film = disabledFilm ?? imageInfo?.catalog.defaultFilm,
                  let index = film["film"]?.number.map(Int.init),
                  let stock = imageInfo?.catalog.films.first(where: { $0.index == index }) else { return }
            let filter = settings.fields["monochrome"]?.object?["filter"] ?? .string("neutral")
            let filmFilters: [JSONValue] = ["neutral", "yellow", "orange", "red", "green"].map(JSONValue.string)
            changeSettings {
                $0.film = film
                $0.fields["cameraProfile"] = .null
                $0.fields["rawColor"] = .null
                $0.fields["monochrome"] = stock.monochrome == true
                    ? .object(["filter": filmFilters.contains(filter) ? filter : .string("neutral")]) : .null
            }
        } else {
            disabledFilm = settings.film
            changeSettings {
                $0.film = nil
                if selectedAsset?.isDNG == true { $0.fields["monochrome"] = .null }
            }
        }
    }

    func selectFilm(_ index: Int) {
        guard let stock = imageInfo?.catalog.films.first(where: { $0.index == index }) else { return }
        applyLook(stock.key)
    }

    func selectCameraProfile(_ id: String) {
        guard selectedAsset?.isDNG != true else { return }
        guard imageInfo?.cameraProfiles.contains(where: { $0.id == id }) == true else { return }
        applyLook(id)
    }

    private func applyLook(_ id: String) {
        guard !isApplyingLook, !isExporting, !isTransferringRecipe, !isBenchmarking, !selectionLoading,
              let revision = currentEdits?.document.revision else { return }
        let selection = selectionRevision
        let original = settings
        let source = selectedAsset
        let sourceDocument = currentEdits?.document
        isApplyingLook = true
        Task {
            defer { isApplyingLook = false }
            do {
                if let source, source.isDNG, var document = sourceDocument {
                    document.recipe = try await worker.normalize(original)
                    _ = try await worker.validateDocument(asset: source, json: document.json, previous: nil)
                }
                let applied = try await worker.applyLook(id, to: original)
                if let source, source.isDNG, var document = sourceDocument {
                    document.recipe = applied
                    _ = try await worker.validateDocument(asset: source, json: document.json, previous: nil)
                }
                guard selectionRevision == selection, currentEdits?.document.revision == revision else { return }
                if let film = original.film { disabledFilm = film }
                changeSettings { $0 = applied }
            } catch {
                if selectionRevision == selection { message = error.localizedDescription }
            }
        }
    }

    func importSidecar(_ url: URL) {
        guard let asset = selectedAsset, let snapshot = currentEdits, !isTransferringRecipe else { return }
        guard !asset.isDNG else { message = "Apple RAW DNG recipes cannot be exchanged with desktop decoders."; return }
        requests.cancel()
        worker.cancel()
        isTransferringRecipe = true
        status = "Validating desktop sidecar…"
        Task {
            defer { isTransferringRecipe = false; if active { requestPreview() } }
            do {
                await savePendingEdits()
                let json = try await library.readSidecar(url)
                let validated = try await worker.validateDocument(asset: asset, json: json, previous: nil)
                let document = try snapshot.document.replacing(with: validated)
                guard selectedID == asset.id else { return }
                let imported = NativeEdits(assetID: asset.id, renderVersion: snapshot.renderVersion, document: document)
                try await library.saveEdits(imported, asset: asset)
                currentEdits = imported
                settings = document.recipe
                disabledFilm = nil
                edits.pending.removeValue(forKey: asset.id)
                status = "Desktop edits imported."
            } catch {
                message = "The sidecar was not imported. Existing edits are unchanged. \(error.localizedDescription)"
            }
        }
    }

    func exportSidecar() {
        guard let asset = selectedAsset, let snapshot = currentEdits, !isTransferringRecipe else { return }
        guard !asset.isDNG else { message = "Apple RAW DNG recipes cannot be exchanged with desktop decoders."; return }
        requests.cancel()
        worker.cancel()
        isTransferringRecipe = true
        Task {
            defer { isTransferringRecipe = false; if active { requestPreview() } }
            do {
                await savePendingEdits()
                exportURL = try await worker.exportSidecar(asset: asset, document: snapshot.document)
                status = "Desktop sidecar saved to Documents/Exports."
            } catch { message = error.localizedDescription }
        }
    }

    private func flushEdits() {
        saveTask?.cancel()
        guard !edits.pending.isEmpty || edits.saving else { return }
        var background = UIBackgroundTaskIdentifier.invalid
        let endBackground: @MainActor @Sendable () -> Void = {
            guard background != .invalid else { return }
            let identifier = background
            background = .invalid
            UIApplication.shared.endBackgroundTask(identifier)
        }
        background = UIApplication.shared.beginBackgroundTask(withName: "Save edits", expirationHandler: endBackground)
        Task {
            await savePendingEdits()
            endBackground()
        }
    }

    private func savePendingEdits() async {
        await edits.save(using: { pending, asset in
            var normalized = pending
            normalized.document.recipe = try await self.worker.normalize(pending.document.recipe)
            if asset.isDNG {
                normalized.document = try await self.worker.validateDocument(asset: asset, json: normalized.document.json, previous: nil)
            }
            try await self.library.saveEdits(normalized, asset: asset)
        }, onError: { error, asset in self.showSaveError(error, asset: asset) })
    }

    private func showSaveError(_ error: Error, asset: ImportedAsset) {
        if saveErrors.insert(asset.id).inserted {
            message = "Edits for \(asset.name) could not be saved. Your current edits remain in memory. \(error.localizedDescription)"
        }
    }

    private func runBenchmark() async {
        benchmarkCancellationEvents = []
        isBenchmarking = true
        let wasIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = wasIdleTimerDisabled }
        let sampler = MemorySampler()
        sampler.start()
        var report: [String: Any] = ["schemaVersion": 1, "startedAt": ISO8601DateFormatter().string(from: Date()),
                                     "device": UIDevice.current.model, "systemVersion": UIDevice.current.systemVersion,
                                     "previewMaxEdge": 1536, "filmEnabled": false,
                                     "memorySampleIntervalMilliseconds": 50,
                                     "timingScope": "Pipeline wall time; UI latency is not measured"]
        do {
            let fixture = try await library.benchmarkFixture(arguments: ProcessInfo.processInfo.arguments)
            report["fixture"] = fixture.lastPathComponent
            let start = ContinuousClock.now
            let asset = try await library.importFile(fixture)
            report["importMilliseconds"] = start.millisecondsToNow
            assets.insert(asset, at: 0)
            selectedID = asset.id
            report["memoryAfterImportBytes"] = MemorySampler.footprint()
            status = "Benchmark: preparing and rendering…"
            let metadata = try await worker.prepare(asset: asset)
            imageInfo = metadata
            settings = metadata.defaultRecipe
            asShotTemperature = metadata.asShotTemperature
            let document = RecipeDocument(sourceRevision: metadata.sourceRevision, recipe: settings)
            let snapshot = NativeEdits(assetID: asset.id, renderVersion: metadata.renderVersion, document: document)
            try await library.acceptEdits(snapshot, asset: asset, replacing: nil, persist: false)
            currentEdits = snapshot
            let result = try await worker.render(asset: asset, settings: settings)
            frame = result.frame
            report["prepareMilliseconds"] = metadata.prepareMilliseconds
            report["renderMilliseconds"] = result.renderMilliseconds
            report["sourceRevision"] = result.sourceRevision
            report["renderVersion"] = result.renderVersion
            report["previewWidth"] = result.frame.width
            report["previewHeight"] = result.frame.height
            report["memoryAfterRenderBytes"] = MemorySampler.footprint()
            // Measure color before exports increase memory pressure.
            status = "Benchmark: HSL and color grading…"
            var colorRecipe = settings
            if colorRecipe.hasMonochromeColorSource {
                colorRecipe.fields["cameraProfile"] = .string("Standard")
                colorRecipe.fields["monochrome"] = .null
            }
            var hsl = HSLDraft(recipe: colorRecipe)
            hsl.bands[HSLBand.red.rawValue].hue = 20
            hsl.bands[HSLBand.blue.rawValue].saturation = 30
            hsl.bands[HSLBand.green.rawValue].luminance = 15
            hsl.apply(to: &colorRecipe)
            var grading = GradingDraft(recipe: colorRecipe)
            grading.wheels[.shadows]?.setHue(220)
            grading.wheels[.shadows]?.setStrength(15)
            grading.wheels[.highlights]?.setHue(40)
            grading.wheels[.highlights]?.setStrength(10)
            grading.blending = 65; grading.balance = -10
            grading.apply(to: &colorRecipe)
            let colorStart = ContinuousClock.now
            let color = try await worker.render(asset: asset, settings: colorRecipe)
            report["colorRenderMilliseconds"] = colorStart.millisecondsToNow
            report["colorRenderTimingScope"] = "Recipe normalization and preview render wall time; source-default denoise unchanged"
            report["colorRecipeJSON"] = color.recipe.canonicalJSON
            report["colorPreviewWidth"] = color.frame.width
            report["colorPreviewHeight"] = color.frame.height
            report["memoryAfterColorBytes"] = MemorySampler.footprint()
            status = "Benchmark: advanced film, grain and halation…"
            var advancedFilmRecipe = settings
            if advancedFilmRecipe.hasMonochromeColorSource {
                advancedFilmRecipe.fields["cameraProfile"] = .string("Standard")
                advancedFilmRecipe.fields["monochrome"] = .null
            }
            advancedFilmRecipe.film = metadata.catalog.defaultFilm
            var advancedFilm = FilmDraft(recipe: advancedFilmRecipe, defaults: metadata.catalog.defaultFilm)
            advancedFilm.set("evFilm", .number(0.5))
            advancedFilm.set("evPaper", .number(-0.25))
            advancedFilm.set("couplers", .number(0.4))
            advancedFilm.set("gammaFilm", .number(1.05))
            advancedFilm.set("gammaPaper", .number(0.95))
            advancedFilm.set("tuneM", .number(0.03))
            advancedFilm.set("tuneY", .number(-0.04))
            advancedFilm.set("grain", .bool(true))
            advancedFilm.setGrainBase(6, monochrome: false)
            advancedFilm.set("halation", .bool(true))
            advancedFilm.set("halationAmount", .number(1.2), group: "halationParams")
            advancedFilm.set("boostEv", .number(0.5), group: "halationParams")
            advancedFilm.apply(to: &advancedFilmRecipe)
            let advancedFilmStart = ContinuousClock.now
            let advanced = try await worker.render(asset: asset, settings: advancedFilmRecipe)
            report["advancedFilmRenderMilliseconds"] = advancedFilmStart.millisecondsToNow
            report["advancedFilmRenderTimingScope"] = "Recipe normalization and preview render wall time; source-default denoise unchanged"
            report["advancedFilmRecipeJSON"] = advanced.recipe.canonicalJSON
            report["advancedFilmPreviewWidth"] = advanced.frame.width
            report["advancedFilmPreviewHeight"] = advanced.frame.height
            report["memoryAfterAdvancedFilmBytes"] = MemorySampler.footprint()
            status = "Benchmark: exporting…"
            for format in ExportFormat.allCases {
                let exported = try await worker.export(asset: asset, settings: settings, format: format)
                exportURL = exported.url
                report["\(format.rawValue)ExportMilliseconds"] = exported.milliseconds
                report["\(format.rawValue)ExportFilename"] = exported.url.lastPathComponent
                report["\(format.rawValue)Warnings"] = exported.warnings
                if format == .jpeg {
                    report["exportMilliseconds"] = exported.milliseconds
                    report["exportFilename"] = exported.url.lastPathComponent
                    report["availableMemoryBeforeExportBytes"] = exported.availableMemoryBefore
                    report["memoryAfterExportBytes"] = MemorySampler.footprint()
                }
            }
            let sidecarStart = ContinuousClock.now
            let sidecar = try await worker.exportSidecar(asset: asset, document: document)
            let sidecarJSON = try await library.readSidecar(sidecar)
            let roundTrip = try await worker.validateDocument(asset: asset, json: sidecarJSON, previous: document)
            report["sidecarRoundTripMilliseconds"] = sidecarStart.millisecondsToNow
            report["sidecarFilename"] = sidecar.deletingLastPathComponent().lastPathComponent + "/" + sidecar.lastPathComponent
            report["sidecarRoundTripMatches"] = roundTrip.recipe.canonicalJSON == settings.canonicalJSON
            guard roundTrip.recipe.canonicalJSON == settings.canonicalJSON else {
                throw EditStorageError("The sidecar round trip changed the canonical recipe.")
            }
            var filmRecipe = settings
            filmRecipe.film = metadata.catalog.defaultFilm
            let film = try await worker.render(asset: asset, settings: filmRecipe)
            report["filmRenderMilliseconds"] = film.renderMilliseconds
            report["filmStockIndex"] = film.recipe.filmStock
            report["filmStockKey"] = metadata.catalog.films.first { $0.index == film.recipe.filmStock }?.key
            report["filmRecipeJSON"] = film.recipe.canonicalJSON
            report["memoryAfterFilmBytes"] = MemorySampler.footprint()
            status = "Benchmark: crop, rotation, curves and noise reduction…"
            var editingRecipe = settings
            editingRecipe.fields["crop"] = CropRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8).json
            editingRecipe.fields["rotation"] = .integer(1)
            var curve = CurveDraft(recipe: editingRecipe)
            _ = curve.add(channel: .master, point: CurvePoint(x: 0.5, y: 0.6))
            curve.apply(to: &editingRecipe)
            var noise = DenoiseSettings(recipe: editingRecipe)
            noise.intensity = 6
            noise.apply(to: &editingRecipe)
            let editingStart = ContinuousClock.now
            let editing = try await worker.render(asset: asset, settings: editingRecipe)
            report["editingRenderMilliseconds"] = editingStart.millisecondsToNow
            report["editingRenderTimingScope"] = "Recipe normalization, RAW reprepare and preview render wall time"
            report["editingRecipeJSON"] = editing.recipe.canonicalJSON
            report["editingPreviewWidth"] = editing.frame.width
            report["editingPreviewHeight"] = editing.frame.height
            report["memoryAfterEditingBytes"] = MemorySampler.footprint()
            report["status"] = "ok"
            status = "Benchmark complete. See Documents/Benchmarks/report.json."
        } catch {
            report["status"] = "error"
            report["error"] = error.localizedDescription
            status = "Benchmark failed. See Documents/Benchmarks/report.json."
            message = error.localizedDescription
        }
        report["benchmarkCancellationEvents"] = benchmarkCancellationEvents
        report["sampledPeakPhysicalFootprintBytes"] = sampler.stop()
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        do { try await library.writeBenchmarkReport(report) }
        catch { message = "Could not write benchmark report: \(error.localizedDescription)" }
        isBenchmarking = false
    }
}
