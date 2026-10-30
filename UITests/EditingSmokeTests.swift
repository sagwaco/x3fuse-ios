import XCTest

@MainActor
final class EditingSmokeTests: XCTestCase {
    func testCropAndCurveDrafts() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()

        let crop = app.buttons["editor.crop"]
        if !crop.waitForExistence(timeout: 5) {
            let fixture = app.cells.containing(.staticText, identifier: "DP2M0643.X3F").firstMatch
            if fixture.waitForExistence(timeout: 10) { fixture.tap() }
        }
        XCTAssertTrue(crop.waitForExistence(timeout: 60), "Seed the simulator library with a RAW fixture before this smoke test.")
        reveal(crop, in: app)
        waitUntilEnabled(crop)
        crop.tap()
        let applyCrop = app.buttons["crop.apply"]
        XCTAssertTrue(applyCrop.waitForExistence(timeout: 30))
        waitUntilEnabled(applyCrop)
        capture("Crop draft", app: app)
        let handle = app.descendants(matching: .any).matching(identifier: "crop.handle.2").firstMatch
        XCTAssertTrue(handle.exists)
        let originalX = handle.frame.midX
        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: -40, dy: -40)))
        XCTAssertLessThan(handle.frame.midX, originalX - 5)
        app.buttons["crop.reset"].tap()
        app.buttons["crop.cancel"].tap()
        XCTAssertFalse(applyCrop.exists)

        reveal(crop, in: app)
        crop.tap()
        waitUntilEnabled(applyCrop)
        app.buttons["crop.aspect"].tap()
        app.buttons["1:1"].tap()
        applyCrop.tap()
        XCTAssertFalse(applyCrop.exists)

        let curves = app.buttons["editor.curves"]
        reveal(curves, in: app)
        curves.tap()
        let applyCurve = app.buttons["curve.apply"]
        XCTAssertTrue(applyCurve.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["curve.channel"].exists)
        capture("Curve draft", app: app)
        let output = app.sliders["Output"]
        let curveScroll = app.scrollViews.containing(.button, identifier: "curve.reset").firstMatch
        reveal(output, in: app, scroll: curveScroll)
        output.adjust(toNormalizedSliderPosition: 0.25)
        reveal(app.buttons["curve.reset"], in: app, scroll: curveScroll)
        app.buttons["curve.reset"].tap()
        app.buttons["curve.cancel"].tap()
        XCTAssertFalse(applyCurve.exists)
        reveal(curves, in: app)
        curves.tap()
        XCTAssertTrue(applyCurve.waitForExistence(timeout: 10))
        reveal(output, in: app, scroll: curveScroll)
        output.adjust(toNormalizedSliderPosition: 0.1)
        applyCurve.tap()
        XCTAssertFalse(applyCurve.exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("Editor after Apply", app: app)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scroll: XCUIElement? = nil) {
        for _ in 0..<6 {
            if element.isHittable { return }
            (scroll ?? app.scrollViews.firstMatch).swipeUp()
        }
        capture("Unreachable control", app: app)
        print(app.debugDescription)
        XCTAssertTrue(element.isHittable)
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 60), .completed)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
