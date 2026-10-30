import Foundation

struct FilmDraft {
    private let original: [String: JSONValue]?
    private(set) var fields: [String: JSONValue]
    let defaults: [String: JSONValue]
    var isEnabled: Bool { original != nil }

    init(recipe: EditSettings, defaults: [String: JSONValue]) {
        original = recipe.film
        fields = recipe.film ?? [:]
        self.defaults = defaults
    }

    func number(_ key: String, group: String? = nil) -> Double {
        if let group { return fields[group]?.object?[key]?.number ?? defaults[group]?.object?[key]?.number ?? 0 }
        return fields[key]?.number ?? defaults[key]?.number ?? 0
    }

    func flag(_ key: String) -> Bool { fields[key] == .bool(true) }
    var autoPaper: Bool { fields["evPaper"] == nil || fields["evPaper"] == .null }
    func hasNative(_ effect: String) -> Bool { fields[effect + "Params"]?.object != nil }

    mutating func set(_ key: String, _ value: JSONValue, group: String? = nil) {
        guard isEnabled else { return }
        if let group {
            guard var nested = fields[group]?.object else { return }
            nested[key] = value
            fields[group] = .object(nested)
        } else { fields[key] = value }
    }

    mutating func resetEffect(_ effect: String) {
        guard isEnabled else { return }
        var params = defaults[effect + "Params"]?.object ?? [:]
        if effect == "grain" { params["rmsBase"] = .null }
        fields[effect + "Params"] = .object(params)
    }

    mutating func reset() {
        guard isEnabled else { return }
        for key in ["paper", "negative", "evFilm", "evPaper", "couplers", "gammaFilm", "gammaPaper", "tuneM", "tuneY", "grain", "halation"] {
            fields[key] = defaults[key]
        }
        resetEffect("grain"); resetEffect("halation")
    }

    var grainRMS: [Double] {
        guard case .array(let values) = fields["grainParams"]?.object?["rmsGranularity"] else { return [4.5, 4.5, 4.5] }
        return values.compactMap(\.number)
    }

    func grainBase(monochrome: Bool) -> Double {
        fields["grainParams"]?.object?["rmsBase"]?.number ?? (monochrome ? grainRMS[0] : grainRMS.reduce(0, +) / 3)
    }

    func grainBaseRange(monochrome: Bool) -> ClosedRange<Double> {
        guard !monochrome else { return 0...100 }
        let base = grainBase(monochrome: false)
        let offsets = grainRMS.map { $0 - base }
        let lower = max(0, -(offsets.min() ?? 0))
        let upper = min(100, 100 - (offsets.max() ?? 0))
        return lower...max(lower, upper)
    }

    mutating func setGrainBase(_ value: Double, monochrome: Bool) {
        let base = grainBase(monochrome: monochrome)
        let values = grainRMS.enumerated().map { channel, current in
            monochrome ? (channel == 0 ? value : current) : min(100, max(0, current - base + value))
        }
        set("rmsBase", .number(value), group: "grainParams")
        set("rmsGranularity", .array(values.map(JSONValue.number)), group: "grainParams")
    }

    mutating func setGrainOffset(_ value: Double, channel: Int) {
        let base = grainBase(monochrome: false)
        var values = grainRMS
        values[channel] = min(100, max(0, base + value))
        set("rmsBase", .number(base), group: "grainParams")
        set("rmsGranularity", .array(values.map(JSONValue.number)), group: "grainParams")
    }

    func apply(to recipe: inout EditSettings) {
        guard let original, var film = recipe.film else { return }
        for (key, value) in fields where value != original[key] {
            if let nested = value.object, let old = original[key]?.object {
                var current = film[key]?.object ?? [:]
                for (field, value) in nested where value != old[field] { current[field] = value }
                film[key] = .object(current)
            } else { film[key] = value }
        }
        if film != recipe.film { recipe.film = film }
    }
}
