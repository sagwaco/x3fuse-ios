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

    func loadEdits(for asset: ImportedAsset) throws -> LoadedEdits {
        let url = editsURL(for: asset)
        guard files.fileExists(atPath: url.path) else { return LoadedEdits(data: nil, content: .empty) }
        let data = try Self.readBounded(url)
        struct Header: Decodable { let version: Int; let assetID: UUID }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.assetID == asset.id else { throw EditStorageError("Saved edits belong to another asset. The file was kept unchanged.") }
        switch header.version {
        case 1:
            struct Legacy: Decodable { let settings: LegacyEditSettings }
            let settings = try JSONDecoder().decode(Legacy.self, from: data).settings
            guard settings.isValid else { throw EditStorageError("Saved legacy edits are invalid. The file was kept unchanged.") }
            return LoadedEdits(data: data, content: .legacy(settings))
        case 2:
            return LoadedEdits(data: data, content: .current(try JSONDecoder().decode(NativeEdits.self, from: data)))
        default:
            throw EditStorageError("Saved edits use a newer version. The file was kept unchanged.")
        }
    }

    func saveEdits(_ edits: NativeEdits, for asset: ImportedAsset, replacing expected: Data?) throws -> Data {
        let current = try loadEdits(for: asset)
        guard current.data == expected, edits.assetID == asset.id, edits.version == 2 else {
            throw EditStorageError("Saved edits changed outside this editor. The file was kept unchanged.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(edits)
        guard data.count <= 1_048_576 else { throw EditStorageError("The recipe is larger than 1 MiB.") }
        try data.write(to: editsURL(for: asset), options: .atomic)
        return data
    }

    static func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw EditStorageError("The recipe is larger than 1 MiB.") }
        return data
    }

    private func editsURL(for asset: ImportedAsset) -> URL {
        root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("native-edits.json")
    }
}

actor AssetLibrary {
    let store: AssetStore
    private struct WriteToken { let data: Data? }
    private var savedData: [UUID: WriteToken] = [:]
    init(store: AssetStore = .application) { self.store = store }
    func list() throws -> [ImportedAsset] { try store.list() }
    func importFile(_ url: URL) throws -> ImportedAsset { try store.importFile(url) }
    func loadEdits(_ asset: ImportedAsset) throws -> LoadedEdits { try store.loadEdits(for: asset) }

    func acceptEdits(_ edits: NativeEdits, asset: ImportedAsset, replacing original: Data?, persist: Bool = true) throws {
        if persist {
            savedData[asset.id] = WriteToken(data: try store.saveEdits(edits, for: asset, replacing: original))
        } else {
            guard try store.loadEdits(for: asset).data == original else {
                throw EditStorageError("Saved edits changed while the image was opening.")
            }
            savedData[asset.id] = WriteToken(data: original)
        }
    }

    func saveEdits(_ edits: NativeEdits, asset: ImportedAsset) throws {
        guard let expected = savedData[asset.id] else { throw EditStorageError("Open and validate the saved recipe before editing.") }
        savedData[asset.id] = WriteToken(data: try store.saveEdits(edits, for: asset, replacing: expected.data))
    }

    func readSidecar(_ url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { coordinated in
            result = Result { try AssetStore.readBounded(coordinated) }
        }
        if let error { throw error }
        let data = try result.get()
        guard let text = String(data: data, encoding: .utf8) else { throw EditStorageError("The sidecar is not UTF-8 JSON.") }
        return text
    }


}

@MainActor
final class EditSaveQueue {
    var pending: [UUID: (ImportedAsset, NativeEdits)] = [:]
    private(set) var saving = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func save(using write: (NativeEdits, ImportedAsset) async throws -> Void,
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
