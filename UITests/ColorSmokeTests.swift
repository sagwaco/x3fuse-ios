import XCTest

@MainActor
final class ColorSmokeTests: XCTestCase {
    func testColorDraftsGesturesAndSavedEdits() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openEditor(app)

        let hsl = app.buttons["editor.hsl"]
        reveal(hsl, in: app.scrollViews.firstMatch)
        waitUntilEnabled(hsl)
        hsl.tap()
        let hslScroll = app.scrollViews["hsl.scroll"]
        XCTAssertTrue(app.buttons["hsl.apply"].waitForExistence(timeout: 10))
        let hue = app.sliders["hsl.hue"]
        reveal(hue, in: hslScroll)
        let originalHue = hue.value as? String
        hue.adjust(toNormalizedSliderPosition: 0.8)
        XCTAssertNotEqual(hue.value as? String, originalHue)
        capture("HSL draft", app)
        app.buttons["hsl.cancel"].tap()
        hsl.tap()
        XCTAssertTrue(hue.waitForExistence(timeout: 10))
        XCTAssertEqual(hue.value as? String, originalHue, "Cancel must leave saved HSL unchanged.")
        reveal(app.buttons["hsl.resetBand"], in: hslScroll)
        app.buttons["hsl.resetBand"].tap()
        reveal(hue, in: hslScroll)
        hue.adjust(toNormalizedSliderPosition: (Double(originalHue ?? "") ?? 0) > 0 ? 0.25 : 0.75)
        let savedHue = number(hue)
        app.buttons["hsl.apply"].tap()
        XCTAssertFalse(app.buttons["hsl.apply"].exists)

        let grading = app.buttons["editor.grading"]
        reveal(grading, in: app.scrollViews.firstMatch)
        grading.tap()
        let gradingScroll = app.scrollViews["grading.scroll"]
        XCTAssertTrue(app.buttons["grading.apply"].waitForExistence(timeout: 10))
        let strength = app.sliders["grading.strength"]
        reveal(strength, in: gradingScroll)
        let originalStrength = strength.value as? String
        let originalLuminance = number(app.sliders["grading.luminance"])
        let wheel = app.descendants(matching: .any).matching(identifier: "grading.wheel").firstMatch
        reveal(wheel, in: gradingScroll)
        let center = wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.press(forDuration: 0.1, thenDragTo: wheel.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.2)))
        reveal(strength, in: gradingScroll)
        XCTAssertNotEqual(strength.value as? String, originalStrength, "Dragging the wheel must change its strength.")
        capture("Grading draft", app)
        app.buttons["grading.cancel"].tap()
        grading.tap()
        XCTAssertTrue(strength.waitForExistence(timeout: 10))
        XCTAssertEqual(strength.value as? String, originalStrength, "Cancel must leave saved grading unchanged.")
        reveal(app.buttons["grading.resetZone"], in: gradingScroll)
        app.buttons["grading.resetZone"].tap()
        reveal(strength, in: gradingScroll)
        strength.adjust(toNormalizedSliderPosition: 0.25)
        let luminance = app.sliders["grading.luminance"]
        reveal(luminance, in: gradingScroll)
        luminance.adjust(toNormalizedSliderPosition: originalLuminance > 0 ? 0.25 : 0.75)
        let savedLuminance = number(luminance)
        app.buttons["grading.apply"].tap()
        XCTAssertFalse(app.buttons["grading.apply"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        // Backgrounding must flush the saved edits before the process restarts.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        app.launch()
        openEditor(app)
        reveal(hsl, in: app.scrollViews.firstMatch)
        waitUntilEnabled(hsl)
        hsl.tap()
        XCTAssertTrue(hue.waitForExistence(timeout: 10))
        XCTAssertEqual(number(hue), savedHue, accuracy: 0.001, "Stored f32 values can round the draft value.")
        app.buttons["hsl.cancel"].tap()
        reveal(grading, in: app.scrollViews.firstMatch)
        grading.tap()
        XCTAssertTrue(luminance.waitForExistence(timeout: 10))
        XCTAssertEqual(number(luminance), savedLuminance, accuracy: 0.001)
        capture("Saved grading after restart", app)
        app.buttons["grading.cancel"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func number(_ slider: XCUIElement) -> Double {
        Double(slider.value as? String ?? "") ?? .nan
    }

    private func openEditor(_ app: XCUIApplication) {
        if !app.buttons["editor.hsl"].waitForExistence(timeout: 5) {
            let fixture = app.cells.containing(.staticText, identifier: "DP0Q0010.X3F").firstMatch
            XCTAssertTrue(fixture.waitForExistence(timeout: 10), "Seed this simulator with a copied Quattro RAW before running the UI suite.")
            fixture.tap()
        }
        XCTAssertTrue(app.buttons["editor.hsl"].waitForExistence(timeout: 60))
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        if element.isHittable { return }
        for _ in 0..<5 {
            scroll.swipeUp()
            if element.isHittable { return }
        }
        for _ in 0..<5 {
            scroll.swipeDown()
            if element.isHittable { return }
        }
        XCTFail("The color control is not reachable: \(element.identifier)")
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 60), .completed)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
