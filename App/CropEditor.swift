import SwiftUI

struct CropEditor: View {
    @ObservedObject var model: AppModel
    let session: CropSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var crop: CropRect
    @State private var frame: PixelFrame?
    @State private var error: String?
    @State private var aspect = "Free"
    @State private var dragStart: CropRect?
    private let presets = ["Free", "Original", "1:1", "4:3", "3:2", "16:9", "3:4", "2:3", "9:16"]

    init(model: AppModel, session: CropSession) {
        self.model = model; self.session = session
        _crop = State(initialValue: CropRect(recipe: session.recipe))
    }

    private var sourceAspect: Double {
        let ratio = session.imageSize.width / session.imageSize.height
        return session.rotation % 2 == 0 ? ratio : 1 / ratio
    }
    private var selectedRatio: Double? {
        if aspect == "Original" { return sourceAspect }
        let parts = aspect.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? parts[0] / parts[1] : nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    if let frame {
                        let scale = min(geometry.size.width / Double(frame.width), geometry.size.height / Double(frame.height))
                        let size = CGSize(width: Double(frame.width) * scale, height: Double(frame.height) * scale)
                        cropImage(frame, size: size)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    } else {
                        VStack(spacing: 16) {
                            if let error {
                                Text(error).multilineTextAlignment(.center)
                                Button("Reload preview") { Task { await loadPreview() } }
                            } else { ProgressView("Preparing uncropped preview…") }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 180)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Aspect ratio", selection: $aspect) {
                            ForEach(presets, id: \.self) { Text($0).tag($0) }
                        }.pickerStyle(.menu).accessibilityIdentifier("crop.aspect")
                        HStack {
                            Button("Reset crop") { setCrop(session.cameraCrop); aspect = "Free" }
                                .accessibilityIdentifier("crop.reset")
                            Spacer()
                            Button("Full frame") { setCrop(.full); aspect = "Original" }
                        }
                        Text("Drag the corners to resize. Drag inside the crop to move it.")
                            .font(.caption).foregroundStyle(.secondary)
                        if session.recipe["straighten"] != 0 {
                            Text("Straightening is hidden while cropping and will be restored when you apply.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("Precise crop") { preciseControls }
                    }.padding(.horizontal)
                }.frame(maxHeight: 190)
            }
            .padding(.vertical)
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("crop.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { model.applyCrop(crop, session: session); dismiss() }
                        .disabled(frame == nil).accessibilityIdentifier("crop.apply")
                }
            }
            .onChange(of: aspect) { _, _ in
                if let ratio = selectedRatio { setCrop(CropRect.ratio(ratio, rotation: session.rotation, image: session.imageSize)) }
            }
            .task(id: phase) { if phase == .active, frame == nil { await loadPreview() } }
        }
    }

    private func setCrop(_ value: CropRect) {
        crop = value.fitted(pitch: session.recipe["pitch"], yaw: session.recipe["yaw"], image: session.imageSize)
    }

    private func loadPreview() async {
        error = nil
        do { frame = try await model.cropPreview(session) }
        catch is CancellationError { error = "Preview paused. Return to the app and reload." }
        catch { self.error = error.localizedDescription }
    }

    private func cropImage(_ frame: PixelFrame, size: CGSize) -> some View {
        let displayed = crop.rotated(session.rotation)
        let rect = CGRect(x: displayed.x * size.width, y: displayed.y * size.height,
                          width: displayed.width * size.width, height: displayed.height * size.height)
        return ZStack(alignment: .topLeading) {
            PixelView(frame: frame, sourceID: session.asset.id).allowsHitTesting(false).accessibilityHidden(true)
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size)); path.addRect(rect)
            }.fill(.black.opacity(0.55), style: FillStyle(eoFill: true)).allowsHitTesting(false)
            Rectangle().fill(.clear).contentShape(Rectangle())
                .overlay(Rectangle().stroke(.white, lineWidth: 2))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .gesture(DragGesture().onChanged { value in
                    if dragStart == nil { dragStart = displayed }
                    let moved = (dragStart ?? displayed).moved(dx: value.translation.width / size.width, dy: value.translation.height / size.height)
                    setCrop(moved.rotated(4 - session.rotation))
                }.onEnded { _ in dragStart = nil })
                .accessibilityLabel("Crop selection").accessibilityHint("Use Precise crop controls to adjust its position and size.")
            Path { path in
                for fraction in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + rect.width * fraction, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * fraction))
                }
            }.stroke(.white.opacity(0.5), lineWidth: 1).allowsHitTesting(false)
            ForEach(0..<4, id: \.self) { corner in
                let left = corner == 0 || corner == 3
                let top = corner == 0 || corner == 1
                Circle().fill(.white).frame(width: 14, height: 14)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    .position(x: left ? rect.minX : rect.maxX, y: top ? rect.minY : rect.maxY)
                    .gesture(DragGesture(coordinateSpace: .named("cropImage")).onChanged { value in
                        if dragStart == nil { dragStart = displayed }
                        let point = CGPoint(x: value.location.x / size.width, y: value.location.y / size.height)
                        let resized = (dragStart ?? displayed).resized(corner: corner, point: point,
                                                                      ratio: selectedRatio.map { $0 / sourceAspect })
                        setCrop(resized.rotated(4 - session.rotation))
                    }.onEnded { _ in dragStart = nil })
                    .accessibilityLabel(["Top left crop corner", "Top right crop corner", "Bottom right crop corner", "Bottom left crop corner"][corner])
                    .accessibilityIdentifier("crop.handle.\(corner)")
            }
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: "cropImage")
    }

    private var preciseControls: some View {
        let displayed = crop.rotated(session.rotation)
        return VStack {
            preciseSlider("Horizontal position", value: displayed.x, range: 0...max(0.001, 1 - displayed.width)) { value in
                setCrop(displayed.moved(dx: value - displayed.x, dy: 0).rotated(4 - session.rotation))
            }
            preciseSlider("Vertical position", value: displayed.y, range: 0...max(0.001, 1 - displayed.height)) { value in
                setCrop(displayed.moved(dx: 0, dy: value - displayed.y).rotated(4 - session.rotation))
            }
            preciseSlider("Width", value: displayed.width, range: CropRect.minimum...max(CropRect.minimum, 1 - displayed.x)) { value in
                aspect = "Free"
                var result = displayed; result.width = value
                setCrop(result.rotated(4 - session.rotation))
            }
            preciseSlider("Height", value: displayed.height, range: CropRect.minimum...max(CropRect.minimum, 1 - displayed.y)) { value in
                aspect = "Free"
                var result = displayed; result.height = value
                setCrop(result.rotated(4 - session.rotation))
            }
        }
    }

    private func preciseSlider(_ title: String, value: Double, range: ClosedRange<Double>, change: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading) {
            Text("\(title): \(Int(value * 100))%").font(.caption)
            Slider(value: Binding(get: { value }, set: change), in: range)
                .accessibilityLabel(title).accessibilityValue("\(Int(value * 100)) percent")
        }
    }
}
