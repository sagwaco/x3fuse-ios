import Foundation
import X3FuseEngine
import os

struct PreviewResult {
    let frame: PixelFrame
    let prepareMilliseconds: Double
    let renderMilliseconds: Double
    let asShotTemperature: Double
    let sourceRevision: String
    let renderVersion: Int
    let recipe: EditSettings
}

struct ExportResult {
    let url: URL
    let milliseconds: Double
    let availableMemoryBefore: UInt64
    var warnings: [String] = []
}

private struct EngineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg, tiff, dng
    var id: Self { self }
    var title: String { switch self { case .jpeg: return "JPEG"; case .tiff: return "Rendered TIFF"; case .dng: return "Original DNG" } }
    var fileExtension: String { switch self { case .jpeg: return "jpg"; case .tiff: return "tif"; case .dng: return "dng" } }
}

struct FilmStock: Decodable, Identifiable {
    let index: Int
    let key: String
    let name: String
    let monochrome: Bool?
    var id: Int { index }
}

struct FilmCatalog: Decodable {
    let films: [FilmStock]
    var papers: [FilmStock] = []
    let defaultFilm: [String: JSONValue]
}

struct ImageInfo {
    let width: Int
    let height: Int
    let sourceRevision: String
    let renderVersion: Int
    let defaultRecipe: EditSettings
    let asShotTemperature: Double
    let catalog: FilmCatalog
    let prepareMilliseconds: Double
}

protocol ImageEngine: Sendable {
    func prepare(asset: ImportedAsset) async throws -> ImageInfo
    func normalize(_ settings: EditSettings) async throws -> EditSettings
    func validateDocument(asset: ImportedAsset, json: String, previous: RecipeDocument?) async throws -> RecipeDocument
    func exportSidecar(asset: ImportedAsset, document: RecipeDocument) async throws -> URL
    func render(asset: ImportedAsset, settings: EditSettings) async throws -> PreviewResult
    func export(asset: ImportedAsset, settings: EditSettings, format: ExportFormat) async throws -> ExportResult
    func cancel()
    func setActive(_ active: Bool)
    func releaseSession()
}

final class EngineWorker: ImageEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sagwa.X3Fuse.native.engine", qos: .userInitiated)
    private let lock = NSLock()
    private var activeToken: OpaquePointer?
    private var epoch: UInt64 = 0
    private var enabled = true
    private var session: OpaquePointer?
    private var sourceID: UUID?
    private var info: [String: Any] = [:]

    func cancel() {
        lock.lock()
        epoch &+= 1
        if let activeToken { x3f_cancel_set(activeToken) }
        lock.unlock()
    }

    func setActive(_ active: Bool) {
        lock.lock()
        guard enabled != active else { lock.unlock(); return }
        enabled = active
        epoch &+= 1
        if !active, let activeToken { x3f_cancel_set(activeToken) }
        lock.unlock()
    }

    func releaseSession() {
        cancel()
        queue.async { self.clearSession() }
    }

    func prepare(asset: ImportedAsset) async throws -> ImageInfo {
        try await perform { token in
            let start = ContinuousClock.now
            try self.open(asset, token: token)
            let elapsed = start.millisecondsToNow
            let defaults = try JSONSerialization.data(withJSONObject: self.info["defaultRecipe"] as? [String: Any] ?? [:])
            let recipe = try self.normalizeNow(EditSettings(canonicalJSON: String(decoding: defaults, as: UTF8.self)))
            let catalogJSON = try self.stringResult { x3f_film_catalog($0, $1) }
            return ImageInfo(width: self.info["width"] as? Int ?? 1, height: self.info["height"] as? Int ?? 1,
                             sourceRevision: self.info["sourceRevision"] as? String ?? "",
                             renderVersion: self.info["renderVersion"] as? Int ?? 0,
                             defaultRecipe: recipe, asShotTemperature: self.info["asShotTemperature"] as? Double ?? 6500,
                             catalog: try JSONDecoder().decode(FilmCatalog.self, from: Data(catalogJSON.utf8)),
                             prepareMilliseconds: elapsed)
        }
    }

    func normalize(_ settings: EditSettings) async throws -> EditSettings {
        try await serial { try self.normalizeNow(settings) }
    }

    private func normalizeNow(_ settings: EditSettings) throws -> EditSettings {
        let patch = try settings.patchJSON
        let json = try stringResult { output, error in
            settings.canonicalJSON.withCString { recipe in
                patch.withCString { x3f_recipe_patch(recipe, $0, output, error) }
            }
        }
        return try EditSettings(canonicalJSON: json)
    }

    func validateDocument(asset: ImportedAsset, json: String, previous: RecipeDocument?) async throws -> RecipeDocument {
        try await perform { token in
            try self.open(asset, token: token)
            var recipeJSON: UnsafeMutablePointer<CChar>?
            defer { x3f_string_free(recipeJSON) }
            let validated = try self.stringResult { output, error in
                json.withCString { x3f_document_validate(self.session, $0, output, &recipeJSON, nil, error) }
            }
            if var previous {
                previous.recipe = try self.normalizeNow(previous.recipe)
                let previousJSON = try previous.json
                try self.checked { error in
                    previousJSON.withCString { old in validated.withCString { x3f_document_check_previous(old, $0, error) } }
                }
            }
            guard let recipeJSON else { throw EngineFailure(message: "The engine returned no canonical recipe.") }
            return try self.readDocument(validated, recipeJSON: String(cString: recipeJSON))
        }
    }

    private func readDocument(_ json: String, recipeJSON: String) throws -> RecipeDocument {
        struct WireDocument: Decodable {
            let version: Int
            let sourceRevision: String
            let revision: UInt64
            let updatedMs: UInt64
        }
        let value = try JSONDecoder().decode(WireDocument.self, from: Data(json.utf8))
        let recipe = try EditSettings(canonicalJSON: recipeJSON)
        return RecipeDocument(version: value.version, sourceRevision: value.sourceRevision,
                              revision: value.revision, updatedMs: value.updatedMs, recipe: recipe)
    }

    func exportSidecar(asset: ImportedAsset, document: RecipeDocument) async throws -> URL {
        try await perform { token in
            try self.open(asset, token: token)
            var normalized = document
            normalized.recipe = try self.normalizeNow(document.recipe)
            let recipe = try normalized.recipe.json
            let previous = try normalized.json
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exports", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let output = directory.appendingPathComponent(asset.name + ".x3fuse.json")
            _ = try self.stringResult { result, error in
                output.path.withCString { path in recipe.withCString { recipe in previous.withCString {
                    x3f_sidecar_write(self.session, path, recipe, normalized.revision, $0, result, error)
                } } }
            }
            return output
        }
    }

    func render(asset: ImportedAsset, settings: EditSettings) async throws -> PreviewResult {
        try await perform { token in
            let prepareStart = ContinuousClock.now
            try self.open(asset, token: token)
            let prepareMS = prepareStart.millisecondsToNow
            guard let session = self.session else { throw EngineFailure(message: "The image session is unavailable.") }
            let normalized = try self.normalizeNow(settings)
            let recipe = try normalized.json
            var frame = X3fFrame()
            defer { x3f_frame_free(&frame) }
            let interval = AppMetrics.signposter.beginInterval("Render")
            defer { AppMetrics.signposter.endInterval("Render", interval) }
            let start = ContinuousClock.now
            try self.checked { error in
                recipe.withCString { x3f_session_render(session, $0, 1536, token, &frame, error) }
            }
            let renderMS = start.millisecondsToNow
            let width = Int(frame.width), height = Int(frame.height), stride = Int(frame.stride)
            guard width > 0, height > 0, width <= 4096, height <= 4096,
                  stride == width * 4, frame.len == stride * height, let pixels = frame.bytes else {
                throw EngineFailure(message: "The engine returned an invalid image buffer.")
            }
            let copied = PixelFrame(width: width, height: height, bytesPerRow: stride,
                                    pixels: Data(bytes: pixels, count: frame.len))
            return PreviewResult(frame: copied, prepareMilliseconds: prepareMS, renderMilliseconds: renderMS,
                                 asShotTemperature: self.info["asShotTemperature"] as? Double ?? 6500,
                                 sourceRevision: self.info["sourceRevision"] as? String ?? "",
                                 renderVersion: self.info["renderVersion"] as? Int ?? 0, recipe: normalized)
        }
    }

    func export(asset: ImportedAsset, settings: EditSettings, format: ExportFormat) async throws -> ExportResult {
        try await perform { token in
            try self.open(asset, token: token)
            guard let session = self.session else { throw EngineFailure(message: "The image session is unavailable.") }
            let normalized = try self.normalizeNow(settings)
            let recipe = try normalized.json
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = URL(fileURLWithPath: asset.name).deletingPathExtension().lastPathComponent
            let output = directory.appendingPathComponent("\(stem)-\(UUID().uuidString).\(format.fileExtension)")
            let available = UInt64(os_proc_available_memory())
            let pixels = UInt64(self.info["width"] as? Int ?? 0) * UInt64(self.info["height"] as? Int ?? 0)
            let estimatedExtra = pixels * 24 + 64 * 1024 * 1024
            guard available == 0 || available >= estimatedExtra else {
                throw EngineFailure(message: "Not enough available memory for a full-resolution export. Close other apps and try again.")
            }
            let interval = AppMetrics.signposter.beginInterval("Export")
            defer { AppMetrics.signposter.endInterval("Export", interval) }
            let start = ContinuousClock.now
            var warnings: [String] = []
            switch format {
            case .jpeg:
                try self.checked { error in
                    recipe.withCString { recipe in output.path.withCString {
                        x3f_session_export_jpeg(session, recipe, $0, 95, false, token, error)
                    } }
                }
            case .tiff:
                try self.checked { error in
                    recipe.withCString { recipe in output.path.withCString {
                        x3f_session_export_tiff(session, recipe, $0, X3F_PROFILE_SRGB, true, false, token, error)
                    } }
                }
            case .dng:
                guard let opcodes = Bundle.main.url(forResource: "opcodes", withExtension: nil) else {
                    throw EngineFailure(message: "The bundled DNG lens corrections are missing.")
                }
                var messages: UnsafeMutablePointer<CChar>?
                defer { x3f_string_free(messages) }
                try self.checked { error in
                    output.path.withCString { path in opcodes.path.withCString {
                        x3f_session_export_dng(session, path, $0, false, false, token, &messages, error)
                    } }
                }
                if let messages { warnings = (try? JSONDecoder().decode([String].self, from: Data(String(cString: messages).utf8))) ?? [] }
            }
            return ExportResult(url: output, milliseconds: start.millisecondsToNow, availableMemoryBefore: available, warnings: warnings)
        }
    }

    private func open(_ asset: ImportedAsset, token: OpaquePointer) throws {
        if sourceID == asset.id { return }
        clearSession()
        let interval = AppMetrics.signposter.beginInterval("Prepare")
        defer { AppMetrics.signposter.endInterval("Prepare", interval) }
        var opened: OpaquePointer?
        do {
            try checked { error in
                asset.sourceURL(in: AssetStore.application.root).path.withCString {
                    x3f_session_open($0, token, &opened, error)
                }
            }
            guard let opened else { throw EngineFailure(message: "The engine did not open the image.") }
            var json: UnsafeMutablePointer<CChar>?
            defer { x3f_string_free(json) }
            try checked { x3f_session_info(opened, &json, $0) }
            guard let json,
                  let metadata = try JSONSerialization.jsonObject(with: Data(String(cString: json).utf8)) as? [String: Any],
                  metadata["defaultRecipe"] is [String: Any] else {
                throw EngineFailure(message: "The engine returned invalid image metadata.")
            }
            session = opened
            sourceID = asset.id
            info = metadata
        } catch {
            x3f_session_free(opened)
            throw error
        }
    }

    private func clearSession() {
        x3f_session_free(session)
        session = nil
        sourceID = nil
        info = [:]
    }

    private func checked(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> X3fStatus) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = call(&message)
        defer { x3f_string_free(message) }
        if status == X3F_ERR_CANCELLED { throw CancellationError() }
        guard status == X3F_OK else {
            throw EngineFailure(message: message.map { String(cString: $0) } ?? "The image engine could not complete this operation.")
        }
    }

    private func stringResult(_ call: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> X3fStatus) throws -> String {
        var output: UnsafeMutablePointer<CChar>?
        defer { x3f_string_free(output) }
        try checked { call(&output, $0) }
        guard let output else { throw EngineFailure(message: "The engine returned no JSON.") }
        return String(cString: output)
    }

    private func serial<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try work()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func perform<T>(_ work: @escaping (OpaquePointer) throws -> T) async throws -> T {
        let scheduledEpoch = lock.withLock { epoch }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let token = x3f_cancel_new() else {
                    continuation.resume(throwing: EngineFailure(message: "Could not allocate a cancellation token."))
                    return
                }
                self.lock.lock()
                let allowed = self.enabled && self.epoch == scheduledEpoch
                if allowed { self.activeToken = token }
                self.lock.unlock()
                defer {
                    self.lock.withLock { self.activeToken = nil }
                    x3f_cancel_free(token)
                }
                guard allowed else { continuation.resume(throwing: CancellationError()); return }
                do { continuation.resume(returning: try work(token)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

extension ContinuousClock.Instant {
    var millisecondsToNow: Double {
        let parts = duration(to: .now).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
}
