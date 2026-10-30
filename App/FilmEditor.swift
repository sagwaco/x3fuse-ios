import SwiftUI

struct FilmEditor: View {
    @ObservedObject var model: AppModel
    let sourceID: UUID
    let catalog: FilmCatalog
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FilmDraft

    init(model: AppModel, sourceID: UUID, recipe: EditSettings, catalog: FilmCatalog) {
        self.model = model; self.sourceID = sourceID; self.catalog = catalog
        _draft = State(initialValue: FilmDraft(recipe: recipe, defaults: catalog.defaultFilm))
    }

    private var monochrome: Bool {
        catalog.films.first { $0.index == Int(draft.number("film")) }?.monochrome == true
    }

    private func toggle(_ title: String, key: String) -> some View {
        Toggle(title, isOn: Binding(get: { draft.flag(key) }, set: { draft.set(key, .bool($0)) }))
            .accessibilityIdentifier("film.\(key)")
    }

    private func control(_ title: String, key: String, group: String? = nil, range: ClosedRange<Double>, step: Double) -> some View {
        valueControl(title, value: Binding(get: { draft.number(key, group: group) }, set: { draft.set(key, .number($0), group: group) }),
                     range: range, step: step, id: "film.\(key)")
    }

    private func valueControl(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, id: String) -> some View {
        VStack(alignment: .leading) {
            Stepper(value: value, in: range, step: step) {
                Text("\(title): \(value.wrappedValue.formatted(.number.precision(.fractionLength(0...2))))")
            }.accessibilityLabel(title).accessibilityValue(value.wrappedValue.formatted())
                .disabled(range.lowerBound == range.upperBound)
            if range.lowerBound < range.upperBound {
                Slider(value: value, in: range, step: step)
                    .accessibilityLabel(title).accessibilityValue(value.wrappedValue.formatted()).accessibilityIdentifier(id)
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Film simulation is experimental. Previews can take longer. Changes apply when you tap Apply.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !draft.isEnabled {
                        Text("Enable Film in the editor to use these controls.").accessibilityIdentifier("film.disabled")
                    }
                }
                Group {
                    Section("Film and paper") {
                        control("Film exposure (EV)", key: "evFilm", range: -3...3, step: 0.05)
                        toggle("Scan negative directly", key: "negative")
                        if !draft.flag("negative") {
                            Picker("Paper", selection: Binding(get: { Int(draft.number("paper")) }, set: { draft.set("paper", .integer(Int64($0))) })) {
                                ForEach(catalog.papers) { Text($0.name).tag($0.index) }
                            }.accessibilityIdentifier("film.paper")
                            Toggle("Automatic paper exposure", isOn: Binding(get: { draft.autoPaper }, set: { draft.set("evPaper", $0 ? .null : .number(0)) }))
                                .accessibilityIdentifier("film.autoPaper")
                            if !draft.autoPaper { control("Paper exposure (EV)", key: "evPaper", range: -6...6, step: 0.05) }
                            Text("More paper exposure darkens the print.").font(.caption).foregroundStyle(.secondary)
                            control("Paper gamma", key: "gammaPaper", range: 0.5...2, step: 0.01)
                            if !monochrome {
                                control("Paper magenta filtration", key: "tuneM", range: -1...1, step: 0.01)
                                control("Paper yellow filtration", key: "tuneY", range: -1...1, step: 0.01)
                            }
                        }
                        control("Film gamma", key: "gammaFilm", range: 0.5...2, step: 0.01)
                        if !monochrome { control("Couplers", key: "couplers", range: 0...1, step: 0.01) }
                    }
                    grainSection
                    halationSection
                    Section {
                        Button("Reset advanced film controls") { draft.reset() }.accessibilityIdentifier("film.reset")
                        Text("Reset keeps the film stock, calibration and random seed. It restores native grain and halation parameters.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!draft.isEnabled)
            }.accessibilityIdentifier("film.scroll")
            .navigationTitle("Advanced film").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("film.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        if model.selectedID == sourceID { model.changeSettings { draft.apply(to: &$0) } }
                        dismiss()
                    }.disabled(!draft.isEnabled || model.settings.film == nil).accessibilityIdentifier("film.apply")
                }
            }
        }
    }

    private var grainSection: some View {
        Section("Grain") {
            toggle("Grain", key: "grain")
            if draft.hasNative("grain") {
                if draft.flag("grain") {
                    let base = draft.grainBase(monochrome: monochrome)
                    let range = draft.grainBaseRange(monochrome: monochrome)
                    valueControl("RMS granularity", value: Binding(get: { draft.grainBase(monochrome: monochrome) }, set: { draft.setGrainBase($0, monochrome: monochrome) }),
                                 range: range, step: 0.5, id: "film.rmsGranularity")
                    if range.lowerBound == range.upperBound {
                        Text("Adjust grain channel offsets to change RMS granularity.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !monochrome {
                        DisclosureGroup("Grain channel offsets") {
                            ForEach(0..<3, id: \.self) { channel in
                                valueControl(["Red offset", "Green offset", "Blue offset"][channel],
                                             value: Binding(get: { draft.grainRMS[channel] - draft.grainBase(monochrome: false) }, set: { draft.setGrainOffset($0, channel: channel) }),
                                             range: -base...(100 - base), step: 0.5, id: "film.grainOffset\(channel)")
                            }
                        }
                    }
                    control("Grain blur", key: "blur", group: "grainParams", range: 0...4, step: 0.01)
                    control("Grain sharpening", key: "multUsmAmount", group: "grainParams", range: 0...4, step: 0.1)
                }
            } else { legacyEffect("grain") }
        }
    }

    private var halationSection: some View {
        Section("Halation") {
            toggle("Halation", key: "halation")
            if draft.hasNative("halation") {
                if draft.flag("halation") {
                    control("Scatter amount", key: "scatterAmount", group: "halationParams", range: 0...1, step: 0.05)
                    control("Scatter scale", key: "scatterSpatialScale", group: "halationParams", range: 0...4, step: 0.1)
                    control("Halation amount", key: "halationAmount", group: "halationParams", range: 0...4, step: 0.05)
                    control("Halation scale", key: "halationSpatialScale", group: "halationParams", range: 0...4, step: 0.1)
                    control("Highlight boost (EV)", key: "boostEv", group: "halationParams", range: 0...20, step: 0.1)
                    control("Highlight protection (EV)", key: "protectEv", group: "halationParams", range: 0...10, step: 0.1)
                    control("Boost range", key: "boostRange", group: "halationParams", range: 0...1, step: 0.05)
                }
            } else { legacyEffect("halation") }
        }
    }

    private func legacyEffect(_ effect: String) -> some View {
        Group {
            Text("This recipe uses legacy \(effect). Its saved parameters are kept until you choose native controls.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Use native \(effect) controls") { draft.resetEffect(effect) }
                .accessibilityIdentifier("film.convert\(effect.capitalized)")
        }
    }
}
