import Foundation

struct ImportedAsset: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let sourceName: String
    let importedAt: Date

    func sourceURL(in root: URL) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(sourceName)
    }
}

struct AssetStore {
    let root: URL
    private let files = FileManager.default

    static let application = AssetStore(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Assets", isDirectory: true))

    func list() throws -> [ImportedAsset] {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        return try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("asset.json")),
                      let asset = try? JSONDecoder().decode(ImportedAsset.self, from: data),
                      directory.lastPathComponent == asset.id.uuidString,
                      asset.sourceName == URL(fileURLWithPath: asset.sourceName).lastPathComponent,
                      asset.sourceName.hasPrefix("source."),
                      files.fileExists(atPath: asset.sourceURL(in: root).path) else { return nil }
                return asset
            }.sorted { $0.importedAt > $1.importedAt }
    }

    func importFile(_ source: URL) throws -> ImportedAsset {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let ext = source.pathExtension.lowercased()
        guard ["x3f", "x3i"].contains(ext) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Choose an X3F or X3I RAW image."])
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let asset = ImportedAsset(id: id, name: source.lastPathComponent, sourceName: "source.\(ext)", importedAt: Date())
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { coordinated in
            do {
                let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw CocoaError(.fileReadInvalidFileName)
                }
                try files.copyItem(at: coordinated, to: staging.appendingPathComponent(asset.sourceName))
                let handle = try FileHandle(forWritingTo: staging.appendingPathComponent(asset.sourceName))
                defer { try? handle.close() }
                try handle.synchronize()
            } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        try JSONEncoder().encode(asset).write(to: staging.appendingPathComponent("asset.json"), options: .atomic)
        try files.moveItem(at: staging, to: destination)
        return asset
    }

    func loadEdits(for asset: ImportedAsset) throws -> EditSettings {
        let url = editsURL(for: asset)
        guard files.fileExists(atPath: url.path) else { return EditSettings() }
        let envelope = try JSONDecoder().decode(NativeEdits.self, from: Data(contentsOf: url))
        guard envelope.version == 1, envelope.assetID == asset.id, envelope.settings.isValid else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Saved edits are not supported. The saved file will be kept unchanged."])
        }
        return envelope.settings
    }

    func saveEdits(_ settings: EditSettings, for asset: ImportedAsset) throws {
        _ = try loadEdits(for: asset)
        guard settings.isValid else { throw CocoaError(.fileWriteInvalidFileName) }
        let envelope = NativeEdits(version: 1, assetID: asset.id, settings: settings)
        try JSONEncoder().encode(envelope).write(to: editsURL(for: asset), options: .atomic)
    }

    private func editsURL(for asset: ImportedAsset) -> URL {
        root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("native-edits.json")
    }
}

private struct NativeEdits: Codable {
    let version: Int
    let assetID: UUID
    let settings: EditSettings
}

struct EditSettings: Codable, Equatable {
    var exposure = 0.0
    var temperature: Double?
    var tint = 0.0

    var isValid: Bool {
        exposure.isFinite && (-5...5).contains(exposure) && tint.isFinite && (-2000...2000).contains(tint)
            && (temperature.map { $0.isFinite && (500...50000).contains($0) } ?? true)
    }

    func recipeJSON(defaults: [String: Any]) throws -> String {
        guard isValid else { throw CocoaError(.coderInvalidValue) }
        var recipe = defaults
        recipe["exposure"] = exposure
        recipe["temperature"] = temperature as Any? ?? NSNull()
        recipe["tint"] = tint
        recipe["whiteBalanceGains"] = NSNull()
        recipe["film"] = NSNull()
        return String(decoding: try JSONSerialization.data(withJSONObject: recipe), as: UTF8.self)
    }
}

actor AssetLibrary {
    let store: AssetStore
    init(store: AssetStore = .application) { self.store = store }
    func list() throws -> [ImportedAsset] { try store.list() }
    func importFile(_ url: URL) throws -> ImportedAsset { try store.importFile(url) }
    func loadEdits(_ asset: ImportedAsset) throws -> EditSettings { try store.loadEdits(for: asset) }
    func saveEdits(_ settings: EditSettings, asset: ImportedAsset) throws { try store.saveEdits(settings, for: asset) }
}

@MainActor
final class EditSaveQueue {
    var pending: [UUID: (ImportedAsset, EditSettings)] = [:]
    private(set) var saving = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func save(using write: (EditSettings, ImportedAsset) async throws -> Void,
              onError: (Error, ImportedAsset) -> Void) async {
        if saving {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        saving = true
        defer {
            saving = false
            let completed = waiters
            waiters.removeAll()
            completed.forEach { $0.resume() }
        }
        var failed = Set<UUID>()
        while let (id, entry) = pending.first(where: { !failed.contains($0.key) }) {
            do {
                try await write(entry.1, entry.0)
                if pending[id]?.1 == entry.1 { pending.removeValue(forKey: id) }
            } catch {
                failed.insert(id)
                onError(error, entry.0)
            }
        }
    }
}

// A new request replaces the pending request while one render is in progress.
struct LatestRequest<Value> {
    private(set) var revision: UInt64 = 0
    private var pending: (UInt64, Value)?

    mutating func submit(_ value: Value) {
        revision &+= 1
        pending = (revision, value)
    }

    mutating func take() -> (UInt64, Value)? {
        defer { pending = nil }
        return pending
    }

    mutating func cancel() {
        revision &+= 1
        pending = nil
    }
}
