import SwiftUI

struct CurveEditor: View {
    @ObservedObject var model: AppModel
    let sourceID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CurveDraft
    @State private var channel = CurveChannel.master
    @State private var selected = 0

    init(model: AppModel, sourceID: UUID, recipe: EditSettings) {
        self.model = model; self.sourceID = sourceID
        _draft = State(initialValue: CurveDraft(recipe: recipe))
    }

    private var points: [CurvePoint] { draft.channels[channel] ?? CurveDraft.identity }
    private var point: CurvePoint { points[min(selected, points.count - 1)] }
    private var color: Color { switch channel { case .master: return .primary; case .red: return .red; case .green: return .green; case .blue: return .blue } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Channel", selection: $channel) {
                        ForEach(CurveChannel.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).accessibilityIdentifier("curve.channel")
                    graph.aspectRatio(1, contentMode: .fit).frame(maxWidth: 420).frame(maxWidth: .infinity)
                    Text("Tap the graph to add a point. Drag a point to adjust it. Changes apply when you tap Apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Selected point", selection: $selected) {
                        ForEach(points.indices, id: \.self) { Text("Point \($0 + 1)").tag($0) }
                    }
                    pointControl("Input", value: point.x, disabled: selected == 0 || selected == points.count - 1) { value in
                        draft.move(selected, channel: channel, to: CurvePoint(x: value, y: point.y))
                    }
                    pointControl("Output", value: point.y) { value in
                        draft.move(selected, channel: channel, to: CurvePoint(x: point.x, y: value))
                    }
                    HStack {
                        Button("Add point") {
                            if let point = draft.insertionPoint(channel: channel, selected: selected),
                               let index = draft.add(channel: channel, point: point) { selected = index }
                        }
                        .disabled(draft.insertionPoint(channel: channel, selected: selected) == nil)
                        .accessibilityIdentifier("curve.add")
                        Button("Remove point") { draft.remove(selected, channel: channel); selected = max(0, selected - 1) }
                            .disabled(selected == 0 || selected == points.count - 1)
                        Spacer()
                        Button("Reset channel") { draft.reset(channel); selected = 0 }
                            .accessibilityIdentifier("curve.reset")
                    }
                }.padding()
            }
            .navigationTitle("Curves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("curve.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if model.selectedID == sourceID { model.changeSettings { draft.apply(to: &$0) } }
                        dismiss()
                    }.accessibilityIdentifier("curve.apply")
                }
            }
            .onChange(of: channel) { _, _ in selected = 0 }
        }
    }

    private var graph: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Rectangle().fill(Color.secondary.opacity(0.08))
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        if let index = draft.add(channel: channel, point: CurvePoint(x: value.location.x / size.width, y: 1 - value.location.y / size.height)) { selected = index }
                    })
                Path { path in
                    for fraction in [0.25, 0.5, 0.75] {
                        path.move(to: CGPoint(x: size.width * fraction, y: 0))
                        path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * fraction))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    }
                }.stroke(Color.secondary.opacity(0.3), lineWidth: 1).allowsHitTesting(false).accessibilityHidden(true)
                Path { path in
                    for (index, sample) in CurveDraft.samples(points).enumerated() {
                        let point = CGPoint(x: sample.x * size.width, y: (1 - sample.y) * size.height)
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }.stroke(color, lineWidth: 2).allowsHitTesting(false).accessibilityHidden(true)
                ForEach(points.indices, id: \.self) { index in
                    let point = points[index]
                    Button { selected = index } label: {
                        Circle().fill(index == selected ? Color.accentColor : color).frame(width: 13, height: 13)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .position(x: point.x * size.width, y: (1 - point.y) * size.height)
                    .gesture(DragGesture(coordinateSpace: .named("curveGraph")).onChanged { value in
                        selected = index
                        draft.move(index, channel: channel, to: CurvePoint(x: value.location.x / size.width, y: 1 - value.location.y / size.height))
                    })
                    .accessibilityLabel("Point \(index + 1)")
                    .accessibilityValue("Input \(Int(point.x * 100)) percent, output \(Int(point.y * 100)) percent")
                    .accessibilityHint("Use Input and Output below to adjust.")
                }
            }
            .overlay(Rectangle().stroke(Color.secondary, lineWidth: 1).allowsHitTesting(false))
            .coordinateSpace(name: "curveGraph")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Curve graph, \(channel.title)")
        }
        .padding(22)
    }

    private func pointControl(_ title: String, value: Double, disabled: Bool = false, change: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value * 100))%")
            Slider(value: Binding(get: { value }, set: change), in: 0...1, step: 1 / 255)
                .disabled(disabled).accessibilityLabel(title).accessibilityValue("\(Int(value * 100)) percent")
        }
    }
}

struct DetailControls: View {
    @ObservedObject var model: AppModel
    @State private var draft: DenoiseDraft
    @State private var dragging = false

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: DenoiseDraft(recipe: model.settings))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.selectedAsset?.isDNG != true {
                Text(model.isPreparingNoise ? "Applying noise reduction…" : "Noise reduction updates when you release a slider.")
                    .font(.caption).foregroundStyle(.secondary)
                slider("Denoise intensity", value: $draft.value.intensity, range: 0...10, step: 1)
                Picker("Algorithm", selection: Binding(get: { draft.value.algorithm }, set: { draft.value.algorithm = $0; commit() })) {
                    Text("NLM").tag("nlm")
                    Text("BM3D").tag("bm3d")
                }
                Toggle("Luminance noise", isOn: Binding(get: { draft.value.luminance }, set: { draft.value.luminance = $0; commit() }))
                Toggle("Chroma noise", isOn: Binding(get: { draft.value.chroma }, set: { draft.value.chroma = $0; commit() }))
                slider("Denoise strength", value: $draft.value.strength, range: 0.1...3, step: 0.1)
                Text("BM3D can take longer. RAW preparation runs in the background.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("Sharpen: \(Int(model.settings["sharpen"]))")
                Slider(value: Binding(get: { model.settings["sharpen"] }, set: { value in model.changeSettings { $0["sharpen"] = value } }), in: 0...100, step: 1)
                    .accessibilityLabel("Sharpen")
            }
        }
        .onChange(of: model.settings) { _, recipe in
            if !dragging { draft = DenoiseDraft(recipe: recipe) }
        }
    }

    private func commit() {
        if let noise = draft.finishGesture() { model.applyDenoise(noise) }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1))))")
            Slider(value: Binding(get: { value.wrappedValue }, set: { newValue in
                value.wrappedValue = newValue
                if !dragging { commit() }
            }), in: range, step: step) { editing in
                dragging = editing
                if !editing { commit() }
            }.accessibilityLabel(title).accessibilityValue(value.wrappedValue.formatted())
        }
    }
}
