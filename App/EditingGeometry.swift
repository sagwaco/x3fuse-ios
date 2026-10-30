import Foundation

struct CropRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)
    static let minimum = 0.001

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    init(recipe: EditSettings) {
        guard let crop = recipe.fields["crop"]?.object else { self = .full; return }
        self.init(x: crop["x"]?.number ?? 0, y: crop["y"]?.number ?? 0,
                  width: crop["width"]?.number ?? 1, height: crop["height"]?.number ?? 1)
    }

    var json: JSONValue {
        let crop = normalized
        if crop == .full { return .null }
        return .object(["x": .number(crop.x), "y": .number(crop.y), "width": .number(crop.width), "height": .number(crop.height)])
    }

    var normalized: CropRect {
        let x = min(max(x, 0), 1 - Self.minimum), y = min(max(y, 0), 1 - Self.minimum)
        return CropRect(x: x, y: y, width: min(max(width, Self.minimum), 1 - x), height: min(max(height, Self.minimum), 1 - y))
    }

    // Crop coordinates precede the clockwise quarter turns used by the renderer.
    func rotated(_ turns: Int) -> CropRect {
        switch (turns % 4 + 4) % 4 {
        case 1: return CropRect(x: 1 - y - height, y: x, width: height, height: width)
        case 2: return CropRect(x: 1 - x - width, y: 1 - y - height, width: width, height: height)
        case 3: return CropRect(x: y, y: 1 - x - width, width: height, height: width)
        default: return self
        }
    }

    static func ratio(_ ratio: Double, rotation: Int, image: CGSize) -> CropRect {
        let target = (rotation % 2 == 0 ? ratio : 1 / ratio) / (image.width / image.height)
        let width = min(1, target), height = min(1, 1 / target)
        return CropRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    func moved(dx: Double, dy: Double) -> CropRect {
        CropRect(x: min(max(x + dx, 0), 1 - width), y: min(max(y + dy, 0), 1 - height), width: width, height: height)
    }

    func resized(corner: Int, point: CGPoint, ratio: Double?) -> CropRect {
        let left = corner == 0 || corner == 3
        let top = corner == 0 || corner == 1
        let anchorX = left ? x + width : x
        let anchorY = top ? y + height : y
        let limitW = left ? anchorX : 1 - anchorX
        let limitH = top ? anchorY : 1 - anchorY
        var w = max(Self.minimum, left ? anchorX - point.x : point.x - anchorX)
        var h = max(Self.minimum, top ? anchorY - point.y : point.y - anchorY)
        if let ratio {
            let minimumW = max(Self.minimum, Self.minimum * ratio)
            let maximumW = min(limitW, limitH * ratio)
            guard minimumW <= maximumW else { return self }
            w = min(max(max(w, h * ratio), minimumW), maximumW)
            h = w / ratio
        } else {
            w = min(w, limitW); h = min(h, limitH)
        }
        return CropRect(x: left ? anchorX - w : anchorX, y: top ? anchorY - h : anchorY, width: w, height: h)
    }

    func fitted(pitch: Double, yaw: Double, image: CGSize) -> CropRect {
        guard pitch != 0 || yaw != 0 else { return normalized }
        let quad = Self.pictureQuad(pitch: pitch, yaw: yaw, image: image)
        func valid(_ crop: CropRect) -> Bool {
            let points = [CGPoint(x: crop.x, y: crop.y), CGPoint(x: crop.x + crop.width, y: crop.y),
                          CGPoint(x: crop.x + crop.width, y: crop.y + crop.height), CGPoint(x: crop.x, y: crop.y + crop.height)]
            return points.allSatisfy { point in
                let p = CGPoint(x: point.x * image.width, y: point.y * image.height)
                return quad.indices.allSatisfy { i in
                    let a = quad[i], b = quad[(i + 1) % quad.count]
                    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= -1e-6 * hypot(b.x - a.x, b.y - a.y)
                }
            }
        }
        let crop = normalized
        if valid(crop) { return crop }
        for center in [CGPoint(x: crop.x + crop.width / 2, y: crop.y + crop.height / 2), CGPoint(x: 0.5, y: 0.5)] {
            func at(_ scale: Double) -> CropRect {
                CropRect(x: center.x - crop.width * scale / 2, y: center.y - crop.height * scale / 2,
                         width: crop.width * scale, height: crop.height * scale)
            }
            var low = max(Self.minimum / crop.width, Self.minimum / crop.height)
            var high = 1.0
            guard valid(at(low)) else { continue }
            for _ in 0..<30 {
                let mid = (low + high) / 2
                if valid(at(mid)) { low = mid } else { high = mid }
            }
            return at(low).normalized
        }
        return crop
    }

    static func pictureQuad(pitch: Double, yaw: Double, image: CGSize) -> [CGPoint] {
        let p = pitch * .pi / 180, y = yaw * .pi / 180
        let cp = cos(p), sp = sin(p), cy = cos(y), sy = sin(y)
        let long = max(image.width, image.height)
        return [CGPoint.zero, CGPoint(x: image.width, y: 0), CGPoint(x: image.width, y: image.height), CGPoint(x: 0, y: image.height)].map { point in
            let x = (point.x - image.width / 2) / long, y = (point.y - image.height / 2) / long
            let z = -cp * sy * x + sp * y + cp * cy
            return CGPoint(x: image.width / 2 + long * ((cy * x + sy) / z - sy / (cp * cy)),
                           y: image.height / 2 + long * ((sp * sy * x + cp * y - sp * cy) / z + sp / cp))
        }
    }
}

struct CropSession: Identifiable {
    let id = UUID()
    let asset: ImportedAsset
    let recipe: EditSettings
    let cameraCrop: CropRect
    let imageSize: CGSize
    var rotation: Int { Int(recipe["rotation"]) }
    var previewRecipe: EditSettings {
        var preview = recipe
        preview.fields["crop"] = .null
        preview["straighten"] = 0
        return preview
    }
}

struct CurvePoint: Equatable {
    var x: Double
    var y: Double
    var json: JSONValue { .object(["x": .number(x), "y": .number(y)]) }
}

enum CurveChannel: String, CaseIterable, Identifiable {
    case master, red, green, blue
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

struct CurveDraft {
    static let identity = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
    private let original: [CurveChannel: [CurvePoint]]
    var channels: [CurveChannel: [CurvePoint]]

    init(recipe: EditSettings) {
        var values: [CurveChannel: [CurvePoint]] = [:]
        for channel in CurveChannel.allCases {
            if case .array(let points) = recipe.fields["curves"]?.object?[channel.rawValue] {
                values[channel] = points.compactMap { point in
                    guard let x = point.object?["x"]?.number, let y = point.object?["y"]?.number else { return nil }
                    return CurvePoint(x: x, y: y)
                }
            } else { values[channel] = Self.identity }
        }
        original = values; channels = values
    }

    mutating func move(_ index: Int, channel: CurveChannel, to point: CurvePoint) {
        guard var points = channels[channel], points.indices.contains(index) else { return }
        var x = points[index].x
        if index > 0 && index < points.count - 1 {
            let previous = points[index - 1].x, next = points[index + 1].x
            let gap = min(1 / 256, (next - previous) / 3)
            let low = max(previous + gap, Double(Float(previous).nextUp))
            let high = min(next - gap, Double(Float(next).nextDown))
            if low <= high { x = Double(Float(min(max(point.x, low), high))) }
        }
        points[index] = CurvePoint(x: x, y: min(max(point.y, 0), 1))
        channels[channel] = points
    }

    mutating func add(channel: CurveChannel, point: CurvePoint) -> Int? {
        guard var points = channels[channel], points.count < 32,
              let next = points.firstIndex(where: { $0.x > point.x }), next > 0,
              point.x - points[next - 1].x >= 1 / 256, points[next].x - point.x >= 1 / 256 else { return nil }
        points.insert(CurvePoint(x: Double(Float(point.x)), y: min(max(point.y, 0), 1)), at: next)
        channels[channel] = points
        return next
    }

    func insertionPoint(channel: CurveChannel, selected: Int) -> CurvePoint? {
        guard let points = channels[channel], points.count < 32 else { return nil }
        let gaps = [selected - 1, selected].filter { $0 >= 0 && $0 + 1 < points.count }
        guard let gap = gaps.max(by: { points[$0 + 1].x - points[$0].x < points[$1 + 1].x - points[$1].x }),
              points[gap + 1].x - points[gap].x >= 2 / 256 else { return nil }
        let x = (points[gap].x + points[gap + 1].x) / 2
        return Self.evaluate(points, tangents: Self.slopes(points), x: x)
    }

    mutating func remove(_ index: Int, channel: CurveChannel) {
        guard var points = channels[channel], index > 0, index < points.count - 1 else { return }
        points.remove(at: index); channels[channel] = points
    }

    mutating func reset(_ channel: CurveChannel) { channels[channel] = Self.identity }

    func apply(to recipe: inout EditSettings) {
        var curves = recipe.fields["curves"]?.object ?? [:]
        for channel in CurveChannel.allCases where channels[channel] != original[channel] {
            curves[channel.rawValue] = .array((channels[channel] ?? Self.identity).map(\.json))
        }
        recipe.fields["curves"] = .object(curves)
    }

    // Match the shared renderer's monotone cubic interpolation.
    static func slopes(_ points: [CurvePoint]) -> [Double] {
        let widths = zip(points, points.dropFirst()).map { $1.x - $0.x }
        let slopes = zip(points, points.dropFirst()).enumerated().map { ($0.element.1.y - $0.element.0.y) / widths[$0.offset] }
        guard points.count > 2 else { return [slopes[0], slopes[0]] }
        func endpoint(_ a: Int, _ b: Int) -> Double {
            let value = ((2 * widths[a] + widths[b]) * slopes[a] - widths[a] * slopes[b]) / (widths[a] + widths[b])
            return value * slopes[a] <= 0 ? 0 : (value < 0 ? -1 : 1) * min(abs(value), 3 * abs(slopes[a]))
        }
        var result = [endpoint(0, 1)]
        for i in 1..<points.count - 1 {
            let w1 = 2 * widths[i] + widths[i - 1], w2 = widths[i] + 2 * widths[i - 1]
            result.append(slopes[i - 1] * slopes[i] <= 0 ? 0 : (w1 + w2) / (w1 / slopes[i - 1] + w2 / slopes[i]))
        }
        result.append(endpoint(widths.count - 1, widths.count - 2))
        return result
    }

    static func samples(_ points: [CurvePoint]) -> [CurvePoint] {
        let tangents = slopes(points)
        return (0...256).map { evaluate(points, tangents: tangents, x: Double($0) / 256) }
    }

    private static func evaluate(_ points: [CurvePoint], tangents: [Double], x: Double) -> CurvePoint {
        let next = max(1, points.firstIndex(where: { $0.x >= x }) ?? points.count - 1)
        let a = points[next - 1], b = points[next], width = b.x - a.x
        let t = min(max((x - a.x) / width, 0), 1), u = 1 - t
        let c1 = a.y + width * tangents[next - 1] / 3, c2 = b.y - width * tangents[next] / 3
        let y = u * u * u * a.y + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * b.y
        return CurvePoint(x: x, y: min(max(y, min(a.y, b.y)), max(a.y, b.y)))
    }
}

struct DenoiseSettings: Equatable {
    var intensity: Double
    var algorithm: String
    var luminance: Bool
    var chroma: Bool
    var strength: Double

    init(recipe: EditSettings) {
        let options = recipe.fields["denoiseOptions"]?.object ?? [:]
        intensity = recipe["denoise"]
        if case .string(let algorithm) = options["algorithm"] { self.algorithm = algorithm } else { algorithm = "nlm" }
        luminance = options["luminance"] == .bool(true)
        chroma = options["chroma"] != .bool(false)
        strength = options["strength"]?.number ?? 1
    }

    func apply(to recipe: inout EditSettings) {
        recipe.fields["denoise"] = .integer(Int64(min(max(intensity.rounded(), 0), 10)))
        var options = recipe.fields["denoiseOptions"]?.object ?? [:]
        options["algorithm"] = .string(algorithm)
        options["luminance"] = .bool(luminance)
        options["chroma"] = .bool(chroma)
        options["strength"] = .number(min(max(strength, 0.1), 3))
        recipe.fields["denoiseOptions"] = .object(options)
    }
}

struct DenoiseDraft {
    var value: DenoiseSettings
    private var committed: DenoiseSettings
    init(recipe: EditSettings) { value = DenoiseSettings(recipe: recipe); committed = value }
    mutating func finishGesture() -> DenoiseSettings? {
        guard value != committed else { return nil }
        committed = value
        return value
    }
}
