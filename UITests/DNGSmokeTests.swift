import XCTest

@MainActor
final class DNGSmokeTests: XCTestCase {
    func testDNGEditingExportAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openEditor(app)
        let exposure = app.sliders["Exposure"]
        reveal(exposure, app)
        waitEnabled(exposure)
        let original = exposure.value as? String
        exposure.adjust(toNormalizedSliderPosition: original?.hasPrefix("+") == true ? 0.4 : 0.6)
        let saved = exposure.value as? String
        XCTAssertNotEqual(saved, original)
        let whiteBalance = app.switches["As-shot white balance"]
        reveal(whiteBalance, app)
        XCTAssertFalse(whiteBalance.isEnabled)
        XCTAssertFalse(app.buttons["editor.cameraMatching"].exists)
        let film = app.switches["editor.filmEnabled"]
        reveal(film, app)
        film.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(film.value as? String, "1")
        waitEnabled(film)
        film.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(film.value as? String, "0")
        let export = app.buttons["Export and recipes"]
        waitEnabled(export)
        export.tap()
        XCTAssertTrue(app.buttons["JPEG"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["16-bit TIFF (sRGB)"].exists)
        XCTAssertFalse(app.buttons["Original DNG"].exists)
        XCTAssertFalse(app.buttons["Import sidecar…"].exists)
        XCTAssertFalse(app.buttons["Export sidecar"].exists)
        app.buttons["JPEG"].tap()
        let share = app.buttons["Share exported file"]
        XCTAssertTrue(share.waitForExistence(timeout: 90))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        app.launch()
        openEditor(app)
        reveal(exposure, app)
        waitEnabled(exposure)
        XCTAssertEqual(exposure.value as? String, saved)
        XCTAssertEqual(app.switches["editor.filmEnabled"].value as? String, "0")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "DNG saved edits"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLargeDNGPreviewAndSavedEdits() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openEditor(app, name: "L1003185.DNG")
        let exposure = app.sliders["Exposure"]
        reveal(exposure, app)
        waitEnabled(exposure)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["editor.previewSource"].exists)
        XCTAssertTrue(app.staticTexts["editor.exportLimit"].exists)
        let original = exposure.value as? String
        exposure.adjust(toNormalizedSliderPosition: original?.hasPrefix("+") == true ? 0.4 : 0.6)
        let saved = exposure.value as? String
        XCTAssertNotEqual(original, saved)
        let export = app.buttons["Export and recipes"]
        waitEnabled(export)
        export.tap()
        XCTAssertTrue(app.buttons["JPEG"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["JPEG"].isEnabled)
        XCTAssertFalse(app.buttons["16-bit TIFF (sRGB)"].isEnabled)
        app.tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        app.launch()
        openEditor(app, name: "L1003185.DNG")
        reveal(exposure, app)
        waitEnabled(exposure)
        XCTAssertEqual(exposure.value as? String, saved)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Large DNG preview and saved edits"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func openEditor(_ app: XCUIApplication, name: String = "accepted-linear-o1.dng") {
        let cell = app.cells.containing(.staticText, identifier: name).firstMatch
        if !cell.waitForExistence(timeout: 3), app.sliders["Exposure"].exists {
            app.navigationBars.buttons.firstMatch.tap()
        }
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "Seed a supported full-active-area DNG copy before this suite.")
        cell.tap()
        XCTAssertTrue(app.sliders["Exposure"].waitForExistence(timeout: 60))
    }

    private func waitEnabled(_ element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: element)], timeout: 60), .completed)
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
        XCTFail("Control is not reachable: \(element.identifier)")
    }
}
