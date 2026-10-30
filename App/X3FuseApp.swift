import SwiftUI
import UniformTypeIdentifiers

@main
struct X3FuseApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background { model.enterBackground() }
                    else { model.setActive(phase == .active) }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in model.setActive(false) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.setActive(true) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.memoryWarning() }
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var importing = false
    @State private var licenses = false

    var body: some View {
        NavigationSplitView {
            List(model.assets, selection: Binding(get: { model.selectedID }, set: { model.select($0) })) { asset in
                NavigationLink(value: asset.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.name).lineLimit(2)
                        Text(asset.importedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if model.assets.isEmpty {
                    ContentUnavailableView("Your RAW library", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Import X3F or X3I files. Originals are copied and kept unchanged."))
                }
            }
            .navigationTitle("X3Fuse Native")
            .toolbar {
                Button { importing = true } label: { Label("Import", systemImage: "plus") }
                    .disabled(model.isImporting || model.isBenchmarking || model.isExporting || model.isTransferringRecipe)
                Button { licenses = true } label: { Label("Licenses", systemImage: "info.circle") }
            }
            .disabled(model.isExporting || model.isBenchmarking || model.isTransferringRecipe)
        } detail: {
            if let asset = model.selectedAsset {
                EditorView(model: model)
                    .navigationTitle(asset.name)
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                ContentUnavailableView("Select an image", systemImage: "photo", description: Text("Open an imported RAW image to edit exposure and white balance."))
            }
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "x3f") ?? .data, UTType(filenameExtension: "x3i") ?? .data],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importFiles(urls)
            case .failure(let error): model.message = error.localizedDescription
            }
        }
        .sheet(isPresented: $licenses) { LicensesView() }
        .alert("X3Fuse", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

private struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("X3Fuse Native is licensed under GPL-3.0. It uses the shared X3Fuse image engine and the following third-party work.")
                    ForEach(["NOTICE", "GPL-3.0", "SPEKTRAFILM_LICENSE", "COLOUR_LICENSE", "NUMPY_LICENSE"], id: \.self) { name in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(name).font(.headline)
                            Text(licenseText(name)).font(.caption).textSelection(.enabled)
                        }
                    }
                }.padding()
            }
            .navigationTitle("Licenses")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func licenseText(_ name: String) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: name == "NOTICE" ? nil : "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "License file unavailable." }
        return text
    }
}

private struct EditorView: View {
    @ObservedObject var model: AppModel
    @State private var importingSidecar = false
    @State private var pendingSidecar: URL?
    @State private var sidecarAssetID: UUID?
    @State private var editingCurves = false
    @State private var editingHSL = false
    @State private var editingGrading = false
    @State private var editingFilm = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let frame = model.frame, let sourceID = model.selectedID { PixelView(frame: frame, sourceID: sourceID) }
                else if model.isRendering || model.isBenchmarking { ProgressView("Preparing RAW…").tint(.white).foregroundStyle(.white) }
            }
            .frame(minHeight: 160, maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        if model.isRendering || model.isExporting { ProgressView().controlSize(.small) }
                        Text(model.status).font(.caption).foregroundStyle(.secondary)
                        if model.currentEdits == nil && !model.selectionLoading {
                            Button("Reload") { model.select(model.selectedID) }
                        }
                    }
                    VStack(spacing: 14) {
                        HStack {
                            Button("Crop") { model.beginCrop() }.accessibilityIdentifier("editor.crop")
                            Spacer()
                            Button { model.rotate(3) } label: { Image(systemName: "rotate.left") }
                                .accessibilityLabel("Rotate left").accessibilityIdentifier("editor.rotateLeft")
                            Button { model.rotate(1) } label: { Image(systemName: "rotate.right") }
                                .accessibilityLabel("Rotate right").accessibilityIdentifier("editor.rotateRight")
                            Spacer()
                            Button("Curves") { editingCurves = true }.accessibilityIdentifier("editor.curves")
                        }
                        HStack {
                            Button("HSL") { editingHSL = true }.accessibilityIdentifier("editor.hsl")
                            Spacer()
                            Button("Color grading") { editingGrading = true }.accessibilityIdentifier("editor.grading")
                        }
                        control("Exposure", value: Binding(get: { model.settings.exposure }, set: { value in model.changeSettings { $0.exposure = value } }),
                                range: -5...5, step: 0.1, display: String(format: "%+.1f EV", model.settings.exposure))
                        DisclosureGroup("Light and color") {
                            ForEach([("contrast", "Contrast"), ("highlights", "Highlights"), ("shadows", "Shadows"),
                                     ("whites", "Whites"), ("blacks", "Blacks"), ("saturation", "Saturation"),
                                     ("vibrance", "Vibrance")], id: \.0) { field, title in
                                control(title, value: Binding(get: { model.settings[field] }, set: { value in model.changeSettings { $0[field] = value } }),
                                        range: -100...100, step: 1, display: String(format: "%+.0f", model.settings[field]))
                            }
                        }
                        Toggle("As-shot white balance", isOn: Binding(get: {
                            model.settings.temperature == nil && !model.settings.hasWhiteBalanceGains && model.settings.tint == 0
                        }, set: { asShot in
                            model.changeSettings {
                                $0.temperature = asShot ? nil : model.asShotTemperature
                                $0.tint = 0
                                $0.fields["whiteBalanceGains"] = .null
                            }
                        }))
                        if model.settings.temperature != nil || model.settings.hasWhiteBalanceGains || model.settings.tint != 0 {
                            control("Temperature", value: Binding(get: { model.settings.temperature ?? model.asShotTemperature }, set: { value in model.changeSettings { $0.temperature = value; $0.fields["whiteBalanceGains"] = .null } }),
                                    range: 500...50000, step: 50, display: "\(Int(model.settings.temperature ?? model.asShotTemperature)) K")
                            control("Tint", value: Binding(get: { model.settings.tint }, set: { value in model.changeSettings { $0.tint = value; $0.temperature = $0.temperature ?? model.asShotTemperature; $0.fields["whiteBalanceGains"] = .null } }),
                                    range: -2000...2000, step: 1, display: String(format: "%+.0f", model.settings.tint))
                        }
                        if let profiles = model.imageInfo?.cameraProfiles, !profiles.isEmpty {
                            Menu {
                                ForEach(profiles) { profile in
                                    Button(profile.name) { model.selectCameraProfile(profile.id) }
                                        .accessibilityIdentifier("editor.cameraMatching.\(profile.id)")
                                }
                            } label: {
                                HStack {
                                    Text("Camera matching")
                                    Spacer()
                                    Text(cameraMatchingName(profiles)).foregroundStyle(.secondary)
                                        .accessibilityIdentifier("editor.cameraMatching.current")
                                }
                            }.accessibilityIdentifier("editor.cameraMatching")
                        }
                        Toggle("Film", isOn: Binding(get: { model.settings.film != nil }, set: { model.setFilmEnabled($0) }))
                            .accessibilityIdentifier("editor.filmEnabled")
                        if model.settings.film != nil, let catalog = model.imageInfo?.catalog {
                            Picker("Film stock", selection: Binding(get: { model.settings.filmStock ?? 0 }, set: { model.selectFilm($0) })) {
                                ForEach(catalog.films) { stock in Text(stock.name).tag(stock.index) }
                            }.accessibilityIdentifier("editor.filmStock")
                            Text("Film simulation is experimental. Previews can take longer.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Advanced film…") { editingFilm = true }.accessibilityIdentifier("editor.filmAdvanced")
                        DisclosureGroup("Detail and noise reduction") {
                            DetailControls(model: model).id(model.selectedID)
                        }.accessibilityIdentifier("editor.detail")
                        HStack {
                            Button("Reset edits") { model.resetEdits() }
                            Spacer()
                            Button("Reload") { if model.currentEdits == nil { model.select(model.selectedID) } else { model.requestPreview() } }
                        }
                    }
                    .disabled(model.isExporting || model.isBenchmarking || model.isTransferringRecipe || model.isApplyingLook || model.selectionLoading || model.currentEdits == nil)
                    Text("Calibrated RAW color · X3I uses the middle exposure").font(.caption).foregroundStyle(.secondary)
                    if let url = model.exportURL {
                        ShareLink(item: url) { Label("Share exported file", systemImage: "square.and.arrow.up") }
                    }
                }.padding()
            }
            .frame(maxHeight: 340)
        }
        .toolbar {
            Menu {
                Section("Rendered image") {
                    Button("JPEG") { model.export(.jpeg) }
                    Button("16-bit TIFF (sRGB)") { model.export(.tiff) }
                }
                Section("Original RAW") {
                    Button("Original DNG") { model.export(.dng) }
                    Text("DNG does not bake edits. Core EXIF metadata only.")
                }
                Section("Desktop edits") {
                    Button("Import sidecar…") { sidecarAssetID = model.selectedID; importingSidecar = true }
                    Button("Export sidecar") { model.exportSidecar() }
                }
            } label: { Label("Export and recipes", systemImage: "square.and.arrow.up") }
            .disabled(model.currentEdits == nil || model.isExporting || model.isBenchmarking || model.isTransferringRecipe || model.isApplyingLook || model.selectionLoading)
        }
        .sheet(item: $model.cropSession, onDismiss: { model.endCrop() }) { session in
            CropEditor(model: model, session: session)
        }
        .sheet(isPresented: $editingCurves) {
            if let sourceID = model.selectedID { CurveEditor(model: model, sourceID: sourceID, recipe: model.settings) }
        }
        .sheet(isPresented: $editingHSL) {
            if let sourceID = model.selectedID { HSLEditor(model: model, sourceID: sourceID, recipe: model.settings) }
        }
        .sheet(isPresented: $editingGrading) {
            if let sourceID = model.selectedID { GradingEditor(model: model, sourceID: sourceID, recipe: model.settings) }
        }
        .sheet(isPresented: $editingFilm) {
            if let sourceID = model.selectedID, let catalog = model.imageInfo?.catalog {
                FilmEditor(model: model, sourceID: sourceID, recipe: model.settings, catalog: catalog)
            }
        }
        .fileImporter(isPresented: $importingSidecar, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): pendingSidecar = urls.first
            case .failure(let error): model.message = error.localizedDescription
            }
        }
        .confirmationDialog("Replace current edits?", isPresented: Binding(get: { pendingSidecar != nil }, set: { if !$0 { pendingSidecar = nil } })) {
            Button("Replace edits", role: .destructive) {
                if let url = pendingSidecar, sidecarAssetID == model.selectedID { model.importSidecar(url) }
                pendingSidecar = nil
            }
            Button("Cancel", role: .cancel) { pendingSidecar = nil }
        } message: {
            Text("Apply the selected desktop sidecar after validating it against this RAW image. The original RAW and sidecar files stay unchanged.")
        }

    }

    private func cameraMatchingName(_ profiles: [CameraProfile]) -> String {
        if model.settings.film != nil { return "Film stock" }
        if model.settings.fields["rawColor"] != nil && model.settings.fields["rawColor"] != .null { return "Full spectrum" }
        if model.settings.fields["monochrome"] != nil && model.settings.fields["monochrome"] != .null { return "Monochrome" }
        let id = model.settings.fields["cameraProfile"] ?? .string("Standard")
        return profiles.first { .string($0.id) == id }?.name ?? "Imported profile"
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(display).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).accessibilityLabel(title).accessibilityValue(display)
        }
    }
}
