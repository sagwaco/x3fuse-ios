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
}

struct ExportResult {
    let url: URL
    let milliseconds: Double
    let availableMemoryBefore: UInt64
}

private struct EngineFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

protocol ImageEngine: Sendable {
    func render(asset: ImportedAsset, settings: EditSettings) async throws -> PreviewResult
    func export(asset: ImportedAsset, settings: EditSettings) async throws -> ExportResult
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

    func render(asset: ImportedAsset, settings: EditSettings) async throws -> PreviewResult {
        try await perform { token in
            let prepareStart = ContinuousClock.now
            try self.open(asset, token: token)
            let prepareMS = prepareStart.millisecondsToNow
            guard let session = self.session else { throw EngineFailure(message: "The image session is unavailable.") }
            let recipe = try settings.recipeJSON(defaults: self.info["defaultRecipe"] as? [String: Any] ?? [:])
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
                                 renderVersion: self.info["renderVersion"] as? Int ?? 0)
        }
    }

    func export(asset: ImportedAsset, settings: EditSettings) async throws -> ExportResult {
        try await perform { token in
            try self.open(asset, token: token)
            guard let session = self.session else { throw EngineFailure(message: "The image session is unavailable.") }
            let recipe = try settings.recipeJSON(defaults: self.info["defaultRecipe"] as? [String: Any] ?? [:])
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stem = URL(fileURLWithPath: asset.name).deletingPathExtension().lastPathComponent
            let output = directory.appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).jpg")
            let available = UInt64(os_proc_available_memory())
            let pixels = UInt64(self.info["width"] as? Int ?? 0) * UInt64(self.info["height"] as? Int ?? 0)
            let estimatedExtra = pixels * 24 + 64 * 1024 * 1024
            guard available == 0 || available >= estimatedExtra else {
                throw EngineFailure(message: "Not enough available memory for a full-resolution export. Close other apps and try again.")
            }
            let interval = AppMetrics.signposter.beginInterval("Export")
            defer { AppMetrics.signposter.endInterval("Export", interval) }
            let start = ContinuousClock.now
            try self.checked { error in
                recipe.withCString { recipe in
                    output.path.withCString { x3f_session_export_jpeg(session, recipe, $0, 95, false, token, error) }
                }
            }
            return ExportResult(url: output, milliseconds: start.millisecondsToNow, availableMemoryBefore: available)
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
