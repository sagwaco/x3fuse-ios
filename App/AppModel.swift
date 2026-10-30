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
    @Published var status = "Import an X3F or X3I image to begin."
    @Published var asShotTemperature = 6500.0

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
        frame = nil
        exportURL = nil
        settings = EditSettings()
        requests.cancel()
        worker.cancel()
        guard let asset = selectedAsset else { return }
        selectionLoading = true
        status = "Opening \(asset.name)…"
        Task {
            let saved: EditSettings
            do { saved = try await library.loadEdits(asset) }
            catch {
                saved = EditSettings()
                if selectedID == asset.id { showSaveError(error, asset: asset) }
            }
            guard selectedID == asset.id else { return }
            settings = edits.pending[asset.id]?.1 ?? saved
            selectionLoading = false
            requestPreview()
        }
    }

    func changeSettings(_ update: (inout EditSettings) -> Void) {
        update(&settings)
        guard let asset = selectedAsset, !selectionLoading else { return }
        edits.pending[asset.id] = (asset, settings)
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
            if !isBenchmarking { requestPreview() }
        }
    }

    func enterBackground() {
        setActive(false)
        flushEdits()
        requests.cancel()
        worker.setActive(false)
    }

    func memoryWarning() {
        requests.cancel()
        worker.releaseSession()
        frame = nil
        status = "Image memory released. Tap Reload to continue."
    }

    func requestPreview() {
        guard let asset = selectedAsset, !selectionLoading else { return }
        requests.submit((asset, settings))
        guard active, !isExporting, !isBenchmarking else { return }
        guard !pumping else { return }
        pumping = true
        Task { await drainPreviews() }
    }

    private func drainPreviews() async {
        isRendering = true
        defer { pumping = false; isRendering = false }
        while active, !isExporting, !isBenchmarking, let (revision, request) = requests.take() {
            status = "Rendering…"
            do {
                let result = try await worker.render(asset: request.0, settings: request.1)
                guard active, requests.revision == revision, selectedID == request.0.id else { continue }
                frame = result.frame
                asShotTemperature = result.asShotTemperature
                status = "\(result.frame.width) × \(result.frame.height) preview · \(Int(result.renderMilliseconds)) ms render"
            } catch is CancellationError {
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

    func export() {
        guard let asset = selectedAsset, !isExporting, active else { return }
        let snapshot = settings
        flushEdits()
        requests.cancel()
        worker.cancel()
        isExporting = true
        exportURL = nil
        status = "Exporting full-resolution JPEG…"
        Task {
            do {
                let result = try await worker.export(asset: asset, settings: snapshot)
                exportURL = result.url
                status = "Saved to Documents/Exports."
            } catch is CancellationError {
                status = "Export cancelled."
            } catch { message = error.localizedDescription; status = "Export failed." }
            isExporting = false
            if active { requestPreview() }
        }
    }

    private func flushEdits() {
        saveTask?.cancel()
        guard !edits.pending.isEmpty || edits.saving else { return }
        var background = UIBackgroundTaskIdentifier.invalid
        let endBackground: @MainActor () -> Void = {
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
        await edits.save(using: { settings, asset in
            try await self.library.saveEdits(settings, asset: asset)
        }, onError: { error, asset in self.showSaveError(error, asset: asset) })
    }

    private func showSaveError(_ error: Error, asset: ImportedAsset) {
        if saveErrors.insert(asset.id).inserted {
            message = "Edits for \(asset.name) could not be saved. Your current edits remain in memory. \(error.localizedDescription)"
        }
    }

    private func runBenchmark() async {
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
            settings = EditSettings()
            report["memoryAfterImportBytes"] = MemorySampler.footprint()
            status = "Benchmark: preparing and rendering…"
            let result = try await worker.render(asset: asset, settings: settings)
            frame = result.frame
            report["prepareMilliseconds"] = result.prepareMilliseconds
            report["renderMilliseconds"] = result.renderMilliseconds
            report["sourceRevision"] = result.sourceRevision
            report["renderVersion"] = result.renderVersion
            report["previewWidth"] = result.frame.width
            report["previewHeight"] = result.frame.height
            report["memoryAfterRenderBytes"] = MemorySampler.footprint()
            status = "Benchmark: exporting…"
            let exported = try await worker.export(asset: asset, settings: settings)
            exportURL = exported.url
            report["exportMilliseconds"] = exported.milliseconds
            report["exportFilename"] = exported.url.lastPathComponent
            report["availableMemoryBeforeExportBytes"] = exported.availableMemoryBefore
            report["memoryAfterExportBytes"] = MemorySampler.footprint()
            report["status"] = "ok"
            status = "Benchmark complete. See Documents/Benchmarks/report.json."
        } catch {
            report["status"] = "error"
            report["error"] = error.localizedDescription
            status = "Benchmark failed. See Documents/Benchmarks/report.json."
            message = error.localizedDescription
        }
        report["sampledPeakPhysicalFootprintBytes"] = sampler.stop()
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())
        do { try await library.writeBenchmarkReport(report) }
        catch { message = "Could not write benchmark report: \(error.localizedDescription)" }
        isBenchmarking = false
    }
}
