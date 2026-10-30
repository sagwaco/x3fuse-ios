import XCTest

@MainActor
final class CameraMatchingSmokeTests: XCTestCase {
    func testQuattroCameraMatchingAndPersistence() { checkCameraMatching("DP0Q0010.X3F") }
    func testMerrillCameraMatchingAndPersistence() { checkCameraMatching("DP2M0643.X3F") }

    private func checkCameraMatching(_ filename: String) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openEditor(app, filename)
        waitUntilEnabled(app.buttons["editor.cameraMatching"])
        let initialProfile = app.staticTexts["editor.cameraMatching.current"].label
        let savedProfile = initialProfile == "Vivid" ? "FCBlue" : "Vivid"
        choose("Standard", app)
        XCTAssertEqual(app.staticTexts["editor.cameraMatching.current"].label, "Standard")
        XCTAssertEqual(app.switches["editor.filmEnabled"].value as? String, "0")
        choose("Vivid", app)
        XCTAssertEqual(app.staticTexts["editor.cameraMatching.current"].label, "Vivid")
        choose("Monochrome", app)
        XCTAssertEqual(app.staticTexts["editor.cameraMatching.current"].label, "Monochrome")
        capture("\(filename) camera matching", app)

        let film = app.switches["editor.filmEnabled"]
        reveal(film, app)
        film.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        waitUntilEnabled(app.buttons["editor.cameraMatching"])
        XCTAssertEqual(film.value as? String, "1")
        XCTAssertEqual(app.staticTexts["editor.cameraMatching.current"].label, "Film stock")
        choose(savedProfile, app)
        let savedLabel = app.staticTexts["editor.cameraMatching.current"].label
        XCTAssertNotEqual(savedLabel, initialProfile)
        XCTAssertNotEqual(savedLabel, "Standard")
        XCTAssertNotEqual(savedLabel, "Monochrome")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        app.launch()
        openEditor(app, filename)
        reveal(app.buttons["editor.cameraMatching"], app)
        waitUntilEnabled(app.buttons["editor.cameraMatching"])
        XCTAssertEqual(app.staticTexts["editor.cameraMatching.current"].label, savedLabel)
        XCTAssertEqual(app.switches["editor.filmEnabled"].value as? String, "0")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("\(filename) saved matching", app)
    }

    private func choose(_ id: String, _ app: XCUIApplication) {
        let menu = app.buttons["editor.cameraMatching"]
        reveal(menu, app)
        waitUntilEnabled(menu)
        menu.tap()
        let choice = app.buttons["editor.cameraMatching.\(id)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        waitUntilEnabled(menu)
    }

    private func openEditor(_ app: XCUIApplication, _ filename: String) {
        let cell = app.cells.containing(.staticText, identifier: filename).firstMatch
        if !cell.waitForExistence(timeout: 3), app.buttons["editor.cameraMatching"].exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "Seed both copied Sigma fixtures before this suite.")
        cell.tap()
        XCTAssertTrue(app.buttons["editor.cameraMatching"].waitForExistence(timeout: 60))
    }

    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        if element.isHittable { return }
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<8 {
            scroll.swipeUp()
            if element.isHittable { return }
        }
        for _ in 0..<8 {
            scroll.swipeDown()
            if element.isHittable { return }
        }
        XCTFail("Camera matching control is not reachable: \(element.identifier)")
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == true AND enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 60), .completed)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
