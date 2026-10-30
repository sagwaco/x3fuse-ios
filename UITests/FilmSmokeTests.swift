import XCTest

@MainActor
final class FilmSmokeTests: XCTestCase {
    func testFilmDraftCancelApplyAndPersistence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        openEditor(app)
        let editorScroll = app.scrollViews.firstMatch
        let enabled = app.switches["editor.filmEnabled"].firstMatch
        reveal(enabled, in: editorScroll)
        waitUntilEnabled(enabled)
        if enabled.value as? String != "1" { tapSwitch(enabled) }
        let advanced = app.buttons["editor.filmAdvanced"]
        reveal(advanced, in: editorScroll)
        advanced.tap()
        XCTAssertTrue(app.buttons["film.apply"].waitForExistence(timeout: 10))
        let form = app.collectionViews["film.scroll"].firstMatch
        let exposure = app.sliders["film.evFilm"]
        reveal(exposure, in: form)
        let original = number(exposure)
        exposure.adjust(toNormalizedSliderPosition: original > 0 ? 0.25 : 0.75)
        XCTAssertNotEqual(number(exposure), original)
        capture("Film exposure draft", app)
        app.buttons["film.cancel"].tap()
        advanced.tap()
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        XCTAssertEqual(number(exposure), original, accuracy: 0.001, "Cancel must preserve film exposure.")

        let negative = app.switches["film.negative"].firstMatch
        reveal(negative, in: form)
        if negative.value as? String == "1" { tapSwitch(negative) }
        let paper = app.buttons["film.paper"].firstMatch
        reveal(paper, in: form)
        paper.tap()
        XCTAssertTrue(app.buttons["Kodak Professional Endura Premier"].waitForExistence(timeout: 5), "The native paper catalog must decode.")
        app.buttons["Kodak Professional Endura Premier"].tap()
        let autoPaper = app.switches["film.autoPaper"].firstMatch
        reveal(autoPaper, in: form)
        if autoPaper.value as? String == "1" { tapSwitch(autoPaper) }
        let paperExposure = app.sliders["film.evPaper"]
        reveal(paperExposure, in: form)
        paperExposure.adjust(toNormalizedSliderPosition: 0.6)
        tapSwitch(autoPaper)
        XCTAssertFalse(paperExposure.exists, "Auto paper exposure must clear the manual value.")
        reveal(exposure, in: form)
        exposure.adjust(toNormalizedSliderPosition: original > 0 ? 0.25 : 0.75)
        let savedExposure = number(exposure)
        let grain = app.switches["film.grain"].firstMatch
        reveal(grain, in: form)
        if grain.value as? String != "1" { tapSwitch(grain) }
        let rms = app.sliders["film.rmsGranularity"]
        reveal(rms, in: form)
        rms.adjust(toNormalizedSliderPosition: 0.1)
        let savedRMS = number(rms)
        capture("Native grain controls", app)
        let halation = app.switches["film.halation"].firstMatch
        reveal(halation, in: form)
        if halation.value as? String != "1" { tapSwitch(halation) }
        let amount = app.sliders["film.halationAmount"]
        reveal(amount, in: form)
        amount.adjust(toNormalizedSliderPosition: 0.4)
        let savedAmount = number(amount)
        capture("Native halation controls", app)
        app.buttons["film.apply"].tap()
        XCTAssertFalse(app.buttons["film.apply"].exists)
        XCTAssertFalse(app.alerts.firstMatch.exists)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.terminate()
        app.launch()
        openEditor(app)
        reveal(advanced, in: app.scrollViews.firstMatch)
        waitUntilEnabled(advanced)
        advanced.tap()
        XCTAssertTrue(exposure.waitForExistence(timeout: 10))
        XCTAssertEqual(number(exposure), savedExposure, accuracy: 0.001)
        reveal(autoPaper, in: form)
        XCTAssertEqual(autoPaper.value as? String, "1")
        reveal(rms, in: form)
        XCTAssertEqual(number(rms), savedRMS, accuracy: 0.001)
        reveal(amount, in: form)
        XCTAssertEqual(number(amount), savedAmount, accuracy: 0.001)
        capture("Saved film controls after restart", app)
        app.buttons["film.cancel"].tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    private func tapSwitch(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    private func number(_ element: XCUIElement) -> Double {
        Double(element.value as? String ?? "") ?? .nan
    }

    private func openEditor(_ app: XCUIApplication) {
        if !app.buttons["editor.hsl"].waitForExistence(timeout: 5) {
            let fixture = app.cells.containing(.staticText, identifier: "DP0Q0010.X3F").firstMatch
            XCTAssertTrue(fixture.waitForExistence(timeout: 10), "Seed this simulator with a copied Quattro RAW.")
            fixture.tap()
        }
        XCTAssertTrue(app.buttons["editor.hsl"].waitForExistence(timeout: 60))
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        if element.isHittable { return }
        for _ in 0..<10 {
            scroll.swipeUp()
            if element.isHittable { return }
        }
        for _ in 0..<10 {
            scroll.swipeDown()
            if element.isHittable { return }
        }
        XCTFail("The film control is not reachable: \(element.identifier)")
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
