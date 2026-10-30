import Foundation

// Keep fields without native controls when a recipe is edited and saved.
enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var number: Double? {
        switch self { case .number(let value): return value; case .integer(let value): return Double(value); default: return nil }
    }
}

struct EditSettings: Codable, Equatable, Sendable {
    let canonicalJSON: String
    private let base: [String: JSONValue]
    private(set) var patch: [String: JSONValue] = [:]

    init() { canonicalJSON = "{}"; base = [:] }

    init(canonicalJSON: String) throws {
        self.canonicalJSON = canonicalJSON
        base = try JSONDecoder().decode([String: JSONValue].self, from: Data(canonicalJSON.utf8))
    }

    init(from decoder: Decoder) throws {
        try self.init(canonicalJSON: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        guard patch.isEmpty else { throw EditStorageError("Normalize the recipe before saving.") }
        var value = encoder.singleValueContainer()
        try value.encode(canonicalJSON)
    }

    var fields: [String: JSONValue] {
        get { base.merging(patch) { _, new in new } }
        set { patch = newValue.filter { base[$0.key] != $0.value } }
    }
    subscript(_ field: String) -> Double {
        get { fields[field]?.number ?? 0 }
        set { patch[field] = .number(newValue) }
    }
    var exposure: Double { get { self["exposure"] } set { self["exposure"] = newValue } }
    var temperature: Double? {
        get { fields["temperature"]?.number }
        set { patch["temperature"] = newValue.map(JSONValue.number) ?? .null }
    }
    var tint: Double { get { self["tint"] } set { self["tint"] = newValue } }
    var film: [String: JSONValue]? {
        get { fields["film"]?.object }
        set { patch["film"] = newValue.map(JSONValue.object) ?? .null }
    }
    var filmStock: Int? { film?["film"]?.number.map(Int.init) }
    var hasWhiteBalanceGains: Bool { fields["whiteBalanceGains"] != nil && fields["whiteBalanceGains"] != .null }
    var patchJSON: String { get throws { String(decoding: try JSONEncoder().encode(patch), as: UTF8.self) } }
    var json: String {
        get throws {
            guard patch.isEmpty else { throw EditStorageError("Normalize the recipe before using it.") }
            return canonicalJSON
        }
    }
}

struct LegacyEditSettings: Codable, Equatable {
    var exposure = 0.0
    var temperature: Double?
    var tint = 0.0

    var isValid: Bool {
        exposure.isFinite && (-5...5).contains(exposure) && tint.isFinite && (-2000...2000).contains(tint)
            && (temperature.map { $0.isFinite && (500...50000).contains($0) } ?? true)
    }

    func applying(to defaults: EditSettings) -> EditSettings {
        var recipe = defaults
        recipe.exposure = exposure
        recipe.temperature = temperature
        recipe.tint = tint
        recipe.fields["whiteBalanceGains"] = .null
        recipe.fields["film"] = .null
        return recipe
    }
}

struct RecipeDocument: Codable, Equatable, Sendable {
    var version = 2
    var sourceRevision: String
    var revision: UInt64 = 1
    var updatedMs: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)
    var recipe: EditSettings

    var json: String {
        get throws {
            let source = String(decoding: try JSONEncoder().encode(sourceRevision), as: UTF8.self)
            return "{\"version\":\(version),\"sourceRevision\":\(source),\"revision\":\(revision),\"updatedMs\":\(updatedMs),\"recipe\":\(try recipe.json)}"
        }
    }

    mutating func setRecipe(_ recipe: EditSettings) {
        self.recipe = recipe
        revision = min(revision, 9_007_199_254_740_990) + 1
        updatedMs = max(UInt64(Date().timeIntervalSince1970 * 1000), updatedMs == .max ? .max : updatedMs + 1)
    }

    func replacing(with imported: RecipeDocument) throws -> RecipeDocument {
        guard sourceRevision == imported.sourceRevision else { throw EditStorageError("The sidecar has different source contents.") }
        let previousRevision = max(revision, imported.revision)
        let previousTime = max(updatedMs, imported.updatedMs)
        guard previousRevision < 9_007_199_254_740_991, previousTime < UInt64.max else {
            throw EditStorageError("The document revision cannot be advanced safely.")
        }
        var replacement = imported
        replacement.version = 2
        replacement.revision = previousRevision + 1
        replacement.updatedMs = max(UInt64(Date().timeIntervalSince1970 * 1000), previousTime + 1)
        return replacement
    }
}

struct NativeEdits: Codable, Equatable, Sendable {
    var version = 2
    let assetID: UUID
    let renderVersion: Int
    var document: RecipeDocument
}

struct LoadedEdits {
    enum Content {
        case empty
        case legacy(LegacyEditSettings)
        case current(NativeEdits)
    }
    let data: Data?
    let content: Content
}

struct EditStorageError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
