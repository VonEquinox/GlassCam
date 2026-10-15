import XCTest

/// Opt-in physical-device acceptance: saves two real photos to the system library.
/// Run only the GlassCamCaptureTests scheme when this side effect is intended.
final class CaptureWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsAndAutomatic24MPSave() throws {
        try checkCapture(outputs: [24], review: false)
    }

    func testSettingsAndAutomatic48MPSaveAndReview() throws {
        try checkCapture(outputs: [48], review: true)
    }

    private func checkCapture(outputs: [Int], review: Bool) throws {
        let app = XCUIApplication(bundleIdentifier: "dev.glasscam.prototype")
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        addUIInterruptionMonitor(withDescription: "Photos add-only authorization") { alert in
            for label in ["Allow Adding Photos", "允许添加照片", "允许添加", "Allow", "允许"] {
                let button = alert.buttons[label]
                if button.exists { button.tap(); return true }
            }
            return false
        }
        func tap(_ element: XCUIElement) {
            let banner = springboard.descendants(matching: .any).matching(identifier: "NotificationShortLookView").firstMatch
            if banner.exists { _ = banner.waitForNonExistence(timeout: 10) }
            if app.state != .runningForeground { app.activate() }
            element.tap()
        }
        for megapixels in outputs {
            let settings = app.buttons["camera.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 30))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: settings)], timeout: 30), .completed)
            tap(settings)
            let resolution = app.segmentedControls["settings.resolution"]
            XCTAssertTrue(resolution.waitForExistence(timeout: 10))
            tap(resolution.buttons["\(megapixels) MP"])
            tap(app.buttons["settings.back"])
            let shutter = app.buttons["camera.shutter"]
            XCTAssertTrue(shutter.waitForExistence(timeout: 10))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed, app.debugDescription)
            tap(shutter)
            // The already-installed app may have no add-only authorization yet.
            for _ in 0..<20 {
                if springboard.alerts.firstMatch.exists {
                    for label in ["Allow Adding Photos", "允许添加照片", "允许添加", "Allow", "允许"] {
                        if springboard.alerts.buttons[label].exists { springboard.alerts.buttons[label].tap(); break }
                    }
                }
                if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved HDR'")).firstMatch.exists { break }
                Thread.sleep(forTimeInterval: 1)
            }
            let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved HDR'")).firstMatch
            XCTAssertTrue(saved.waitForExistence(timeout: 100), app.debugDescription)
            XCTAssertTrue(app.buttons["camera.shutter"].exists, "Capture navigated away from camera")
            XCTAssertTrue(app.buttons["camera.thumbnail"].isEnabled)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Saved-\(megapixels)MP-HDR"; attachment.lifetime = .keepAlways
            add(attachment)
            print("GLASSCAM-ACCEPTANCE \(megapixels)MP \(saved.label)")
        }
        guard review else { return }
        tap(app.buttons["camera.thumbnail"])
        XCTAssertTrue(app.buttons["Share saved HDR photo"].waitForExistence(timeout: 10), app.debugDescription)
        tap(app.buttons["Camera"])
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["camera.settings"].waitForExistence(timeout: 30))
        let restoredSettings = app.buttons["camera.settings"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: restoredSettings)], timeout: 30), .completed)
        tap(restoredSettings)
        XCTAssertTrue(app.segmentedControls["settings.resolution"].buttons["48 MP"].isSelected,
                      "Output preference was not restored after relaunch")
        tap(app.buttons["settings.back"])
    }
}
