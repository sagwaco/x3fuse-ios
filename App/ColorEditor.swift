import SwiftUI

struct ColorValueControl: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -100...100
    let id: String

    var body: some View {
        VStack(alignment: .leading) {
            Stepper(value: $value, in: range, step: 1) {
                Text("\(title): \(value.formatted(.number.precision(.fractionLength(0...1))))")
            }.accessibilityLabel(title).accessibilityValue(value.formatted())
            Slider(value: $value, in: range, step: 1)
                .accessibilityLabel(title).accessibilityValue(value.formatted()).accessibilityIdentifier(id)
        }
    }
}

struct HSLEditor: View {
    @ObservedObject var model: AppModel
    let sourceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft: HSLDraft
    @State private var band = HSLBand.red

    init(model: AppModel, sourceID: UUID, recipe: EditSettings) {
        self.model = model; self.sourceID = sourceID
        _draft = State(initialValue: HSLDraft(recipe: recipe))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ColorSourceWarning(model: model)
                    Picker("Band", selection: $band) {
                        ForEach(HSLBand.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("hsl.band")
                    ColorValueControl(title: "Hue", value: $draft.bands[band.rawValue].hue, id: "hsl.hue")
                    ColorValueControl(title: "Saturation", value: $draft.bands[band.rawValue].saturation, id: "hsl.saturation")
                    ColorValueControl(title: "Luminance", value: $draft.bands[band.rawValue].luminance, id: "hsl.luminance")
                    Button("Reset band") { draft.reset(band) }.accessibilityIdentifier("hsl.resetBand")
                    Button("Reset HSL") { draft.reset() }.accessibilityIdentifier("hsl.reset")
                    Text("Changes apply when you tap Apply.").font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("hsl.scroll")
            .navigationTitle("HSL").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("hsl.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if model.selectedID == sourceID { model.changeSettings { draft.apply(to: &$0) } }
                        dismiss()
                    }.accessibilityIdentifier("hsl.apply")
                }
            }
        }
    }
}

struct GradingEditor: View {
    @ObservedObject var model: AppModel
    let sourceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GradingDraft
    @State private var zone = GradingZone.shadows

    init(model: AppModel, sourceID: UUID, recipe: EditSettings) {
        self.model = model; self.sourceID = sourceID
        _draft = State(initialValue: GradingDraft(recipe: recipe))
    }

    private var wheel: GradingWheel { draft.wheels[zone] ?? GradingWheel() }
    private func binding(_ path: WritableKeyPath<GradingWheel, Double>) -> Binding<Double> {
        Binding(get: { wheel[keyPath: path] }, set: { draft.wheels[zone]?[keyPath: path] = $0 })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ColorSourceWarning(model: model)
                    Picker("Zone", selection: $zone) {
                        ForEach(GradingZone.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("grading.zone")
                    wheelView.frame(width: 240, height: 240).frame(maxWidth: .infinity)
                    Text("Drag the wheel to set hue and strength. Use the controls below for precise adjustments.")
                        .font(.caption).foregroundStyle(.secondary)
                    ColorValueControl(title: "Hue", value: Binding(get: { wheel.degrees }, set: { draft.wheels[zone]?.setHue($0) }), range: 0...359, id: "grading.hue")
                    ColorValueControl(title: "Strength", value: Binding(get: { wheel.strength }, set: { draft.wheels[zone]?.setStrength($0) }), range: 0...100, id: "grading.strength")
                    ColorValueControl(title: "Luminance", value: binding(\.luminance), id: "grading.luminance")
                    Button("Reset wheel") { draft.reset(zone) }.accessibilityIdentifier("grading.resetZone")
                    Divider()
                    ColorValueControl(title: "Blending", value: $draft.blending, range: 0...100, id: "grading.blending")
                    ColorValueControl(title: "Balance", value: $draft.balance, id: "grading.balance")
                    Button("Reset grading") { draft.reset() }.accessibilityIdentifier("grading.reset")
                    Text("Changes apply when you tap Apply.").font(.caption).foregroundStyle(.secondary)
                }.padding().frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.accessibilityIdentifier("grading.scroll")
            .navigationTitle("Color grading").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.accessibilityIdentifier("grading.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if model.selectedID == sourceID { model.changeSettings { draft.apply(to: &$0) } }
                        dismiss()
                    }.accessibilityIdentifier("grading.apply")
                }
            }
        }
    }

    private var wheelView: some View {
        GeometryReader { geometry in
            let radius = geometry.size.width / 2
            ZStack {
                Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: 1 - Double($0) / 12, saturation: 1, brightness: 1) }, center: .center))
                Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: radius))
                Circle().stroke(.secondary, lineWidth: 1)
                Circle().fill(.black).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 2))
                    .position(x: radius * (1 + wheel.x), y: radius * (1 - wheel.y))
            }
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                draft.wheels[zone]?.move(x: (value.location.x - radius) / radius, y: (radius - value.location.y) / radius)
            })
            .accessibilityElement(children: .ignore).accessibilityLabel("\(zone.title) color wheel")
            .accessibilityValue("Hue \(Int(wheel.degrees)) degrees, strength \(Int(wheel.strength)) percent")
            .accessibilityHint("Use Hue and Strength controls below to adjust.").accessibilityIdentifier("grading.wheel")
        }.padding(10)
    }
}

private struct ColorSourceWarning: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if model.settings.hasMonochromeColorSource || model.imageInfo?.catalog.films.first(where: { $0.index == model.settings.filmStock })?.monochrome == true {
            Label("This monochrome source or film hides HSL and grading effects. Your color values are kept.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
