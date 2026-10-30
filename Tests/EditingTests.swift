import XCTest
@testable import X3FuseNative

final class EditingTests: XCTestCase {
    func testFilmGrainEndpointChannelsHaveSafeBaseRanges() async throws {
        let engine = EngineWorker()
        let defaultRecipe = try await engine.normalize(EditSettings())
        let defaults = try XCTUnwrap(defaultRecipe.film)
        for channels in [[0.0, 1, 100], [0, 50, 100]] {
            var recipe = EditSettings()
            var film = defaults
            film["grainParams"] = .object(["rmsGranularity": .array(channels.map(JSONValue.number))])
            recipe.film = film
            let normalized = try await engine.normalize(recipe)
            let draft = FilmDraft(recipe: normalized, defaults: defaults)
            let range = draft.grainBaseRange(monochrome: false)
            XCTAssertEqual(range.lowerBound, range.upperBound)
            XCTAssertEqual(range.lowerBound, draft.grainBase(monochrome: false), accuracy: 1e-12)
            XCTAssertEqual(draft.grainBaseRange(monochrome: true), 0...100)
        }
    }

    func testFilmDraftPreservesNestedCalibrationSeedAndUntouchedFields() async throws {
        let engine = EngineWorker()
        let defaults = try await engine.normalize(EditSettings())
        let original = try await engine.normalize(EditSettings(canonicalJSON: """
        {"seed":1234,"exposure":1.2,"film":{"film":2,"paper":3,"couplersRadius":0.002,
        "grainSize":1.7,"grainAmount":2.1,"grainParams":{"rmsGranularity":[5,8,11],"rmsBase":8,"blur":0.9,"multUsmAmount":2},
        "halationSizeRgb":[50,60,70],"halationParams":{"scatterAmount":0.7,"boostEv":2,"protectEv":5}}}
        """))
        var draft = FilmDraft(recipe: original, defaults: try XCTUnwrap(defaults.film))
        draft.set("evFilm", .number(0.5))
        draft.set("halationAmount", .number(1.5), group: "halationParams")
        draft.setGrainBase(10, monochrome: false)
        XCTAssertEqual(original.film?["evFilm"]?.number, 0, "A cancelled draft leaves the source unchanged.")
        var edited = original
        draft.apply(to: &edited)
        let normalized = try await engine.normalize(edited)
        for key in original.fields.keys where key != "film" { XCTAssertEqual(normalized.fields[key], original.fields[key], key) }
        for key in try XCTUnwrap(original.film).keys where !["evFilm", "grainParams", "halationParams"].contains(key) {
            XCTAssertEqual(normalized.film?[key], original.film?[key], key)
        }
        let grain = try XCTUnwrap(normalized.film?["grainParams"]?.object)
        XCTAssertEqual(grain["rmsGranularity"], .array([.integer(7), .integer(10), .integer(13)]))
        XCTAssertEqual(grain["blur"], original.film?["grainParams"]?.object?["blur"])
        let halation = try XCTUnwrap(normalized.film?["halationParams"]?.object)
        for key in ["scatterAmount", "boostEv", "protectEv"] {
            XCTAssertEqual(halation[key], original.film?["halationParams"]?.object?[key])
        }
        draft = FilmDraft(recipe: original, defaults: try XCTUnwrap(defaults.film))
        draft.setGrainOffset(4, channel: 1)
        edited = original
        draft.apply(to: &edited)
        let offsetRecipe = try await engine.normalize(edited)
        XCTAssertEqual(offsetRecipe.film?["grainParams"]?.object?["rmsGranularity"], .array([.integer(5), .integer(12), .integer(11)]))
        draft = FilmDraft(recipe: offsetRecipe, defaults: try XCTUnwrap(defaults.film))
        draft.resetEffect("grain")
        draft.apply(to: &edited)
        let resetRecipe = try await engine.normalize(edited)
        XCTAssertEqual(resetRecipe.film?["grainParams"], defaults.film?["grainParams"])
        draft = FilmDraft(recipe: original, defaults: try XCTUnwrap(defaults.film))
        draft.setGrainBase(9, monochrome: true)
        XCTAssertEqual(draft.grainRMS, [9, 8, 11], "Monochrome editing keeps inactive channel calibration.")
    }

    func testFilmDraftAutoResetLegacyAndDisabledState() async throws {
        let engine = EngineWorker()
        let defaults = try await engine.normalize(EditSettings())
        let filmDefaults = try XCTUnwrap(defaults.film)
        var recipe = try await engine.normalize(EditSettings(canonicalJSON: """
        {"seed":4321,"film":{"film":4,"evPaper":1,"grainParams":null,"halationParams":null,
        "grainAmount":2,"halationSizeRgb":[45,55,65],"couplersRadius":0.004}}
        """))
        let original = recipe
        var draft = FilmDraft(recipe: recipe, defaults: filmDefaults)
        XCTAssertFalse(draft.hasNative("grain"))
        draft.set("evPaper", .null)
        XCTAssertTrue(draft.autoPaper)
        draft.apply(to: &recipe)
        recipe = try await engine.normalize(recipe)
        XCTAssertEqual(recipe.film?["evPaper"], .null)
        XCTAssertEqual(recipe.film?["grainParams"], .null)
        draft = FilmDraft(recipe: recipe, defaults: filmDefaults)
        draft.resetEffect("grain")
        draft.apply(to: &recipe)
        recipe = try await engine.normalize(recipe)
        XCTAssertNotNil(recipe.film?["grainParams"]?.object)
        XCTAssertEqual(recipe.film?["halationParams"], .null)
        draft = FilmDraft(recipe: recipe, defaults: filmDefaults)
        draft.set("evFilm", .number(2))
        draft.reset()
        draft.apply(to: &recipe)
        recipe = try await engine.normalize(recipe)
        for key in ["film", "couplersRadius", "grainAmount", "halationSizeRgb"] { XCTAssertEqual(recipe.film?[key], original.film?[key], key) }
        XCTAssertEqual(recipe.fields["seed"], original.fields["seed"])
        XCTAssertEqual(recipe.film?["evFilm"], filmDefaults["evFilm"])
        XCTAssertEqual(recipe.film?["grainParams"], filmDefaults["grainParams"])
        var disabled = try await engine.normalize(EditSettings(canonicalJSON: "{\"film\":null,\"seed\":4321}"))
        let disabledOriginal = disabled
        draft = FilmDraft(recipe: disabled, defaults: filmDefaults)
        XCTAssertFalse(draft.isEnabled)
        draft.set("evFilm", .number(1)); draft.resetEffect("grain"); draft.reset(); draft.apply(to: &disabled)
        XCTAssertEqual(disabled, disabledOriginal)
    }

    func testCropMappingAndPresetsAtEveryRotation() {
        let crop = CropRect(x: 0.2, y: 0.15, width: 0.5, height: 0.6)
        let expected = [crop, CropRect(x: 0.25, y: 0.2, width: 0.6, height: 0.5),
                        CropRect(x: 0.3, y: 0.25, width: 0.5, height: 0.6), CropRect(x: 0.15, y: 0.3, width: 0.6, height: 0.5)]
        for rotation in 0..<4 {
            assertCrop(crop.rotated(rotation), expected[rotation])
            assertCrop(crop.rotated(rotation).rotated(4 - rotation), crop)
            let preset = CropRect.ratio(16 / 9, rotation: rotation, image: CGSize(width: 1200, height: 800))
            let sourceRatio = preset.width * 1200 / (preset.height * 800)
            XCTAssertEqual(rotation % 2 == 0 ? sourceRatio : 1 / sourceRatio, 16 / 9, accuracy: 1e-9)
        }
        assertCrop(CropRect.ratio(16 / 9, rotation: 1, image: CGSize(width: 1200, height: 800)),
                   CropRect(x: 0.3125, y: 0, width: 0.375, height: 1))
    }

    func testCropFloatEdgesAndLockedHandlesStayValid() async throws {
        let engine = EngineWorker()
        let edge = CropRect(x: Double(Float(0.1)), y: Double(Float(0.2)), width: Double(Float(0.9)), height: Double(Float(0.8)))
        for rotation in 0..<4 {
            var recipe = EditSettings()
            recipe.fields["crop"] = edge.rotated(rotation).rotated(4 - rotation).json
            recipe.fields["rotation"] = .integer(Int64(rotation))
            _ = try await engine.normalize(recipe)
            for corner in 0..<4 {
                for ratio in [0.25, 1.0, 4.0] {
                    let resized = CropRect.full.resized(corner: corner, point: CGPoint(x: 0.5, y: 0.5), ratio: ratio)
                    XCTAssertGreaterThanOrEqual(resized.width, CropRect.minimum)
                    XCTAssertGreaterThanOrEqual(resized.height, CropRect.minimum)
                    XCTAssertEqual(resized.width / resized.height, ratio, accuracy: 1e-9)
                    recipe.fields["crop"] = resized.rotated(4 - rotation).json
                    _ = try await engine.normalize(recipe)
                }
            }
        }
    }

    func testCropFitsImportedPerspectiveWithoutChangingItsAspect() {
        let image = CGSize(width: 1200, height: 800)
        let fitted = CropRect.full.fitted(pitch: 15, yaw: -10, image: image)
        XCTAssertLessThan(fitted.width, 1)
        XCTAssertEqual(fitted.width / fitted.height, 1, accuracy: 1e-8)
        assertCrop(fitted.fitted(pitch: 15, yaw: -10, image: image), fitted)
        let quad = CropRect.pictureQuad(pitch: 15, yaw: -10, image: image)
        for point in [CGPoint(x: fitted.x, y: fitted.y), CGPoint(x: fitted.x + fitted.width, y: fitted.y),
                      CGPoint(x: fitted.x + fitted.width, y: fitted.y + fitted.height), CGPoint(x: fitted.x, y: fitted.y + fitted.height)] {
            for i in quad.indices {
                let a = quad[i], b = quad[(i + 1) % quad.count]
                let cross = (b.x - a.x) * (point.y * image.height - a.y) - (b.y - a.y) * (point.x * image.width - a.x)
                XCTAssertGreaterThanOrEqual(cross, -0.01)
            }
        }
    }

    func testCropDraftCancelResetAndApplyPreserveOtherGeometry() async throws {
        let engine = EngineWorker()
        let original = try await engine.normalize(EditSettings(canonicalJSON: """
        {"crop":{"x":0.1,"y":0.2,"width":0.8,"height":0.7},"rotation":3,
         "straighten":7,"pitch":10,"yaw":-3,"exposure":1.2,"film":null,"seed":1234}
        """))
        let asset = ImportedAsset(id: UUID(), name: "photo.x3f", sourceName: "source.x3f", importedAt: Date())
        let cameraCrop = CropRect(x: 0, y: 0.05, width: 1, height: 0.9)
        let session = CropSession(asset: asset, recipe: original, cameraCrop: cameraCrop, imageSize: CGSize(width: 1200, height: 800))
        let preview = try await engine.normalize(session.previewRecipe)
        XCTAssertEqual(preview.fields["crop"], .null)
        XCTAssertEqual(preview["straighten"], 0)
        for key in ["rotation", "pitch", "yaw", "exposure", "seed"] { XCTAssertEqual(preview.fields[key], original.fields[key]) }
        XCTAssertEqual(session.recipe.canonicalJSON, original.canonicalJSON, "A cancelled draft must not change the recipe.")
        var applied = original
        applied.fields["crop"] = session.cameraCrop.json
        let reset = try await engine.normalize(applied)
        assertCrop(CropRect(recipe: reset), cameraCrop, accuracy: 1e-6)
        for key in original.fields.keys where key != "crop" { XCTAssertEqual(reset.fields[key], original.fields[key], key) }
    }

    func testCurveEditingKeepsPointsValidAndOtherChannelsUntouched() async throws {
        let engine = EngineWorker()
        let original = try await engine.normalize(EditSettings(canonicalJSON: "{\"film\":null,\"seed\":1234}"))
        var draft = CurveDraft(recipe: original)
        let middle = try XCTUnwrap(draft.add(channel: .red, point: CurvePoint(x: 0.5, y: 0.6)))
        draft.move(middle, channel: .red, to: CurvePoint(x: 1, y: 2))
        draft.move(0, channel: .red, to: CurvePoint(x: 0.9, y: 0.1))
        let points = try XCTUnwrap(draft.channels[.red])
        XCTAssertEqual(points.first?.x, 0)
        XCTAssertEqual(points.last?.x, 1)
        XCTAssertLessThan(Float(points[1].x), Float(points[2].x))
        XCTAssertEqual(points[1].y, 1)
        var edited = original
        draft.apply(to: &edited)
        let normalized = try await engine.normalize(edited)
        for channel in ["master", "green", "blue"] {
            XCTAssertEqual(normalized.fields["curves"]?.object?[channel], original.fields["curves"]?.object?[channel])
        }
        for key in original.fields.keys where key != "curves" { XCTAssertEqual(normalized.fields[key], original.fields[key], key) }
        draft.reset(.red)
        var reset = original
        draft.apply(to: &reset)
        let restored = try await engine.normalize(reset)
        XCTAssertEqual(restored.canonicalJSON, original.canonicalJSON)
        draft.remove(0, channel: .master)
        XCTAssertEqual(draft.channels[.master]?.count, 2)
    }

    func testCurveSamplingMatchesLinesAndNeverOvershoots() {
        for sample in CurveDraft.samples(CurveDraft.identity) { XCTAssertEqual(sample.y, sample.x, accuracy: 1e-12) }
        let points = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 0.25, y: 0.8), CurvePoint(x: 0.5, y: 0.3), CurvePoint(x: 1, y: 0.7)]
        for sample in CurveDraft.samples(points) {
            let next = max(1, points.firstIndex { $0.x >= sample.x } ?? points.count - 1)
            XCTAssertGreaterThanOrEqual(sample.y, min(points[next - 1].y, points[next].y))
            XCTAssertLessThanOrEqual(sample.y, max(points[next - 1].y, points[next].y))
        }
    }

    func testAccessibleCurveInsertionUsesAdjacentGapAndStopsAtLimit() {
        var draft = CurveDraft(recipe: EditSettings())
        let first = draft.insertionPoint(channel: .master, selected: 0)
        XCTAssertEqual(first, CurvePoint(x: 0.5, y: 0.5))
        var selected = 0
        while (draft.channels[.master]?.count ?? 0) < 32 {
            let points = draft.channels[.master] ?? []
            selected = (0..<points.count - 1).max { points[$0 + 1].x - points[$0].x < points[$1 + 1].x - points[$1].x } ?? 0
            guard let point = draft.insertionPoint(channel: .master, selected: selected),
                  let inserted = draft.add(channel: .master, point: point) else { return XCTFail("An available curve gap must accept a point.") }
            selected = inserted
            XCTAssertEqual(point.y, point.x, accuracy: 1e-10)
        }
        XCTAssertNil(draft.insertionPoint(channel: .master, selected: selected))
        XCTAssertNil(draft.add(channel: .master, point: CurvePoint(x: 0.9, y: 0.9)))
        XCTAssertEqual(draft.channels[.red], CurveDraft.identity)
    }

    func testDenoiseDraftCommitsOnReleaseAndKeepsAdvancedOptions() async throws {
        let engine = EngineWorker()
        let original = try await engine.normalize(EditSettings(canonicalJSON: """
        {"denoise":10,"denoiseOptions":{"nlm":{"lumaPatch":5,"chromaSearch":13}},"film":null,"seed":1234}
        """))
        var draft = DenoiseDraft(recipe: original)
        for intensity in 1...7 { draft.value.intensity = Double(intensity) }
        XCTAssertEqual(original["denoise"], 10)
        let committed = try XCTUnwrap(draft.finishGesture())
        XCTAssertEqual(committed.intensity, 7)
        XCTAssertNil(draft.finishGesture())
        var edited = original
        committed.apply(to: &edited)
        let normalized = try await engine.normalize(edited)
        XCTAssertEqual(normalized.fields["denoise"], .integer(7))
        XCTAssertEqual(normalized.fields["denoiseOptions"]?.object?["nlm"], original.fields["denoiseOptions"]?.object?["nlm"])
        for key in original.fields.keys where key != "denoise" && key != "denoiseOptions" { XCTAssertEqual(normalized.fields[key], original.fields[key], key) }
    }

    func testColorDraftsPreserveUntouchedValuesAndMetadata() throws {
        var bands = Array(repeating: JSONValue.object(["hue": .number(0), "saturation": .number(0), "luminance": .number(0)]), count: 8)
        bands[0] = .object(["hue": .number(12), "tag": .string("keep")])
        var recipe = EditSettings()
        recipe.fields["hsl"] = .array(bands)
        recipe.fields["wheels"] = .object(["tag": .string("keep"), "shadows": .object(["x": .number(0.2), "y": .number(0.3), "hue": .number(1), "tag": .string("keep")])])
        let original = recipe.fields
        var hsl = HSLDraft(recipe: recipe)
        hsl.bands[0].saturation = 25
        hsl.apply(to: &recipe)
        if case .array(let edited) = recipe.fields["hsl"] {
            XCTAssertEqual(edited[0].object?["tag"], .string("keep"))
            XCTAssertEqual(edited[0].object?["hue"], .number(12))
            XCTAssertEqual(Array(edited.dropFirst()), Array(bands.dropFirst()))
        } else { XCTFail("Missing HSL bands") }
        var grading = GradingDraft(recipe: recipe)
        grading.wheels[.shadows]?.luminance = 15
        grading.apply(to: &recipe)
        let shadow = recipe.fields["wheels"]?.object?["shadows"]?.object
        XCTAssertEqual(shadow?["hue"], .number(1))
        XCTAssertEqual(shadow?["tag"], .string("keep"))
        XCTAssertEqual(recipe.fields["wheels"]?.object?["tag"], .string("keep"))
        XCTAssertEqual(original["hsl"], .array(bands), "Drafts must leave their source unchanged.")
    }

    func testWheelMappingRememberedHueAndUnitDiscBoundaries() async throws {
        var wheel = GradingWheel()
        wheel.setHue(90)
        XCTAssertEqual(wheel.strength, 0)
        wheel.setStrength(100)
        XCTAssertEqual(wheel.x, 0, accuracy: 0.0001)
        XCTAssertEqual(wheel.y, 1, accuracy: 0.0001)
        wheel.setStrength(0)
        XCTAssertEqual(wheel.degrees, 90, accuracy: 0.01)
        var remembered = EditSettings()
        var rememberedDraft = GradingDraft(recipe: remembered)
        rememberedDraft.wheels[.shadows] = wheel
        rememberedDraft.apply(to: &remembered)
        let rememberedRecipe = try await EngineWorker().normalize(remembered)
        XCTAssertEqual(GradingDraft(recipe: rememberedRecipe).wheels[.shadows]?.degrees ?? 0, 90, accuracy: 0.01)
        wheel.setStrength(50)
        XCTAssertEqual(wheel.y, 0.5, accuracy: 0.0001)
        let engine = EngineWorker()
        for degree in 0...360 {
            wheel.setHue(Double(degree)); wheel.setStrength(100)
            XCTAssertLessThanOrEqual(hypot(wheel.x, wheel.y), 1.0001)
            var recipe = EditSettings()
            var grading = GradingDraft(recipe: recipe)
            grading.wheels[.shadows] = wheel
            grading.apply(to: &recipe)
            _ = try await engine.normalize(recipe)
        }
        wheel.move(x: 3, y: -4)
        XCTAssertEqual(wheel.x, 0.6)
        XCTAssertEqual(wheel.y, -0.8)
        wheel.move(x: .nan, y: 0)
        XCTAssertEqual(wheel.x, 0.6)
    }

    func testColorSectionResetsNormalizeToDefaults() async throws {
        let engine = EngineWorker()
        var recipe = try await engine.normalize(EditSettings())
        var hsl = HSLDraft(recipe: recipe)
        hsl.bands[0].hue = 50; hsl.bands[1].saturation = -40
        hsl.apply(to: &recipe)
        var grading = GradingDraft(recipe: recipe)
        XCTAssertEqual(grading.blending, 50)
        grading.wheels[.shadows]?.setHue(200)
        grading.wheels[.shadows]?.setStrength(40)
        grading.blending = 75
        grading.apply(to: &recipe)
        recipe = try await engine.normalize(recipe)
        hsl = HSLDraft(recipe: recipe); hsl.reset(.red); hsl.apply(to: &recipe)
        XCTAssertEqual(HSLDraft(recipe: recipe).bands[1].saturation, -40)
        hsl = HSLDraft(recipe: recipe); hsl.reset(); hsl.apply(to: &recipe)
        grading = GradingDraft(recipe: recipe); grading.reset(); grading.apply(to: &recipe)
        let reset = try await engine.normalize(recipe)
        let defaults = try await engine.normalize(EditSettings())
        XCTAssertEqual(reset.canonicalJSON, defaults.canonicalJSON)
    }

    private func assertCrop(_ actual: CropRect, _ expected: CropRect, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, file: file, line: line)
    }
}
