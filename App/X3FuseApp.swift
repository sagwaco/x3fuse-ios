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
                    .disabled(model.isImporting || model.isBenchmarking || model.isExporting)
                Button { licenses = true } label: { Label("Licenses", systemImage: "info.circle") }
            }
            .disabled(model.isExporting || model.isBenchmarking)
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
                    }
                    VStack(spacing: 14) {
                        control("Exposure", value: Binding(get: { model.settings.exposure }, set: { value in model.changeSettings { $0.exposure = value } }),
                                range: -5...5, step: 0.1, display: String(format: "%+.1f EV", model.settings.exposure))
                        Toggle("As-shot white balance", isOn: Binding(get: { model.settings.temperature == nil }, set: { asShot in
                            model.changeSettings { $0.temperature = asShot ? nil : model.asShotTemperature; $0.tint = 0 }
                        }))
                        if model.settings.temperature != nil {
                            control("Temperature", value: Binding(get: { model.settings.temperature ?? model.asShotTemperature }, set: { value in model.changeSettings { $0.temperature = value } }),
                                    range: 2000...14000, step: 50, display: "\(Int(model.settings.temperature ?? model.asShotTemperature)) K")
                            control("Tint", value: Binding(get: { model.settings.tint }, set: { value in model.changeSettings { $0.tint = value } }),
                                    range: -150...150, step: 1, display: String(format: "%+.0f", model.settings.tint))
                        }
                        HStack {
                            Button("Reset edits") { model.changeSettings { $0 = EditSettings() } }
                            Spacer()
                            Button("Reload") { model.requestPreview() }
                        }
                    }
                    .disabled(model.isExporting || model.isBenchmarking || model.selectionLoading)
                    Text("Calibrated RAW color · Film disabled · X3I uses the middle exposure").font(.caption).foregroundStyle(.secondary)
                    if let url = model.exportURL {
                        ShareLink(item: url) { Label("Share exported JPEG", systemImage: "square.and.arrow.up") }
                    }
                }.padding()
            }
            .frame(maxHeight: 340)
        }
        .toolbar {
            Button { model.export() } label: { Label("Export JPEG", systemImage: "square.and.arrow.up") }
                .disabled(model.frame == nil || model.isExporting || model.isBenchmarking)
        }
    }

    private func control(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, display: String) -> some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(display).monospacedDigit().foregroundStyle(.secondary) }
            Slider(value: value, in: range, step: step).accessibilityLabel(title).accessibilityValue(display)
        }
    }
}
