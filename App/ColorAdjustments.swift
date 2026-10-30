import Foundation

enum HSLBand: Int, CaseIterable, Identifiable {
    case red, orange, yellow, green, aqua, blue, purple, magenta
    var id: Self { self }
    var title: String { ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"][rawValue] }
}

struct HSLValues: Equatable {
    var hue = 0.0
    var saturation = 0.0
    var luminance = 0.0

    init(_ fields: [String: JSONValue] = [:]) {
        hue = fields["hue"]?.number ?? 0
        saturation = fields["saturation"]?.number ?? 0
        luminance = fields["luminance"]?.number ?? 0
    }
}

struct HSLDraft {
    private let original: [HSLValues]
    var bands: [HSLValues]

    init(recipe: EditSettings) {
        let values: [JSONValue]
        if case .array(let array) = recipe.fields["hsl"] { values = array } else { values = [] }
        bands = HSLBand.allCases.map { HSLValues(values.indices.contains($0.rawValue) ? values[$0.rawValue].object ?? [:] : [:]) }
        original = bands
    }

    mutating func reset(_ band: HSLBand) { bands[band.rawValue] = HSLValues() }
    mutating func reset() { bands = HSLBand.allCases.map { _ in HSLValues() } }

    func apply(to recipe: inout EditSettings) {
        guard bands != original else { return }
        var values: [JSONValue]
        if case .array(let array) = recipe.fields["hsl"] { values = array } else { values = Array(repeating: .object([:]), count: 8) }
        for band in HSLBand.allCases {
            let index = band.rawValue
            var fields = values[index].object ?? [:]
            for (key, path) in [("hue", \HSLValues.hue), ("saturation", \HSLValues.saturation), ("luminance", \HSLValues.luminance)]
                where bands[index][keyPath: path] != original[index][keyPath: path] {
                fields[key] = .number(min(max(bands[index][keyPath: path], -100), 100))
            }
            values[index] = .object(fields)
        }
        recipe.fields["hsl"] = .array(values)
    }
}

enum GradingZone: String, CaseIterable, Identifiable {
    case shadows, midtones, highlights
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct GradingWheel: Equatable {
    var x = 0.0
    var y = 0.0
    var luminance = 0.0
    var hue = 0.0

    init(_ fields: [String: JSONValue] = [:]) {
        x = fields["x"]?.number ?? 0
        y = fields["y"]?.number ?? 0
        luminance = fields["luminance"]?.number ?? 0
        hue = fields["hue"]?.number ?? 0
    }

    var strength: Double { min(hypot(x, y), 1) * 100 }
    var angle: Double { x == 0 && y == 0 ? hue : atan2(y, x) }
    var degrees: Double { let value = angle * 180 / .pi; return value < 0 ? value + 360 : value }

    private static func rounded(_ value: Double) -> Double {
        let result = (value * 10000).rounded() / 10000
        return result == 0 ? 0 : result
    }

    mutating func setHue(_ degrees: Double) {
        guard degrees.isFinite else { return }
        let radius = strength / 100
        let angle = degrees * .pi / 180
        move(x: cos(angle) * radius, y: sin(angle) * radius)
        if radius == 0 { hue = Self.rounded(atan2(sin(angle), cos(angle))) }
    }

    mutating func setStrength(_ strength: Double) {
        guard strength.isFinite else { return }
        let angle = self.angle
        let radius = min(max(strength, 0), 100) / 100
        move(x: cos(angle) * radius, y: sin(angle) * radius)
        if radius == 0 { hue = Self.rounded(angle) }
    }

    mutating func move(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let remembered = angle
        let radius = hypot(x, y)
        self.x = Self.rounded(x / max(radius, 1))
        self.y = Self.rounded(y / max(radius, 1))
        hue = self.x == 0 && self.y == 0 ? Self.rounded(remembered) : 0
    }

}

struct GradingDraft {
    private let original: [GradingZone: GradingWheel]
    private let originalBlending: Double
    private let originalBalance: Double
    var wheels: [GradingZone: GradingWheel]
    var blending: Double
    var balance: Double

    init(recipe: EditSettings) {
        let fields = recipe.fields["wheels"]?.object ?? [:]
        wheels = Dictionary(uniqueKeysWithValues: GradingZone.allCases.map { ($0, GradingWheel(fields[$0.rawValue]?.object ?? [:])) })
        original = wheels
        blending = fields["blending"]?.number ?? 50; originalBlending = blending
        balance = fields["balance"]?.number ?? 0; originalBalance = balance
    }

    mutating func reset(_ zone: GradingZone) { wheels[zone] = GradingWheel() }
    mutating func reset() {
        for zone in GradingZone.allCases { reset(zone) }
        blending = 50; balance = 0
    }

    func apply(to recipe: inout EditSettings) {
        guard wheels != original || blending != originalBlending || balance != originalBalance else { return }
        var fields = recipe.fields["wheels"]?.object ?? [:]
        for zone in GradingZone.allCases where wheels[zone] != original[zone] {
            let value = wheels[zone] ?? GradingWheel(), old = original[zone] ?? GradingWheel()
            var wheel = fields[zone.rawValue]?.object ?? [:]
            for (key, path) in [("x", \GradingWheel.x), ("y", \GradingWheel.y), ("hue", \GradingWheel.hue), ("luminance", \GradingWheel.luminance)]
                where value[keyPath: path] != old[keyPath: path] {
                wheel[key] = .number(value[keyPath: path])
            }
            fields[zone.rawValue] = .object(wheel)
        }
        if blending != originalBlending { fields["blending"] = .number(blending) }
        if balance != originalBalance { fields["balance"] = .number(balance) }
        recipe.fields["wheels"] = .object(fields)
    }
}

extension EditSettings {
    var hasMonochromeColorSource: Bool {
        if fields["cameraProfile"] == .string("Monochrome") || fields["dngDemosaic"] == .string("mono") || (fields["monochrome"] != nil && fields["monochrome"] != .null) { return true }
        if case .array(let matrix) = fields["rawColor"]?.object?["matrix"], matrix.count == 9 {
            return matrix.indices.allSatisfy { index in
                guard let value = matrix[index].number, let first = matrix[index % 3].number else { return false }
                return abs(value - first) < 1e-6
            }
        }
        return false
    }
}
