import XCTest
import Darwin
import AVFoundation

/// Opt-in physical-device acceptance: capture tests save real photos to the system library.
/// Run only the GlassCamCaptureTests scheme when this side effect is intended.
final class CaptureWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSettingsAndAutomatic24MPSave() throws {
        try checkCapture(outputs: [24], review: false)
    }

    func testSettingsAndAutomatic48MPSaveAndReview() throws {
        try checkCapture(outputs: [48], review: true)
    }

    /// Exercises the new controls without adding extra test photos. Physical
    /// source, RAW framing and image quality remain separate device checks.
    func testThreeLensShortcutsAndContinuousRuler() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.glasscam.prototype")
        app.launch()
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed)
        app.buttons["camera.zoom"].tap()
        let ruler = app.sliders["camera.zoom.ruler"]
        XCTAssertTrue(ruler.waitForExistence(timeout: 10))
        for lens in ["Ultra Wide", "Main", "Telephoto", "Main"] {
            let stop = app.scrollViews.buttons["camera.zoom.\(lens)"]
            XCTAssertTrue(stop.waitForExistence(timeout: 10), "Missing \(lens) capability")
            stop.tap()
            XCTAssertTrue(app.staticTexts["camera.zoom.readout"].exists)
        }
        ruler.adjust(toNormalizedSliderPosition: 0.65)
        ruler.adjust(toNormalizedSliderPosition: 0.05)
        app.scrollViews.buttons["camera.zoom.Main"].tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Three-lens-focal-length-controls"; attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Viewfinder"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed,
                       "Zoom changes left the shutter disabled")
    }

    func testMainCaptureSurvivesTermination() throws {
        try checkInterruptedCapture(lens: "Main", checkpoint: "main", terminate: true)
    }

    func testCaptureCapabilityCatalog() throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInUltraWideCamera,
            .builtInWideAngleCamera, .builtInTelephotoCamera], mediaType: .video, position: .back)
        XCTAssertFalse(discovery.devices.isEmpty)
        for device in discovery.devices {
            let sizes = Set(device.formats.flatMap { $0.supportedMaxPhotoDimensions }.map { "\($0.width)x\($0.height)" }).sorted()
            let active = device.activeFormat.supportedMaxPhotoDimensions.map { "\($0.width)x\($0.height)" }
            print("GLASSCAM-CAPABILITY \(device.deviceType.rawValue) active=\(active) all=\(sizes)")
        }
    }

    func testUltraWideCaptureSurvivesBackground() throws {
        try checkInterruptedCapture(lens: "Ultra Wide", checkpoint: "ultra", terminate: false)
    }

    func testTelephotoCaptureSurvivesTermination() throws {
        try checkInterruptedCapture(lens: "Telephoto", checkpoint: "tele", terminate: true)
    }

    func testPinchAndLandscapeCapture() throws {
        let app = try readyCamera()
        defer { XCUIDevice.shared.orientation = .portrait }
        try selectLens("Main", in: app)
        let zoom = app.buttons["camera.zoom"]
        let before = zoom.value as? String
        app.pinch(withScale: 1.8, velocity: 1.2)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (zoom.value as? String) != before
        }, object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed, "Pinch did not change the capture zoom")
        print("GLASSCAM-PINCH \(before ?? "unknown") → \(zoom.value ?? "unknown")")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: app)], timeout: 10), .completed)
        try waitForShutter(app)
        attach(app, name: "Landscape-zoom-viewfinder")
        app.buttons["camera.shutter"].tap()
        let saved = savedStatus(app)
        XCTAssertTrue(saved.waitForExistence(timeout: 120), app.debugDescription)
        print("GLASSCAM-LANDSCAPE \(saved.label)")
        app.buttons["camera.thumbnail"].tap()
        XCTAssertTrue(app.buttons["Share HDR photo"].waitForExistence(timeout: 10))
        attach(app, name: "Landscape-zoom-photo")
        app.buttons["Camera"].tap()
    }

    private func checkInterruptedCapture(lens: String, checkpoint: String, terminate: Bool) throws {
        let app = try readyCamera()
        app.buttons["camera.settings"].tap()
        let resolution = app.segmentedControls["settings.resolution"]
        XCTAssertTrue(resolution.waitForExistence(timeout: 10))
        resolution.buttons["48 MP"].tap()
        app.buttons["settings.back"].tap()
        try waitForShutter(app)
        try selectLens(lens, in: app)
        attach(app, name: "\(checkpoint)-viewfinder")
        let started = Date()
        app.buttons["camera.shutter"].tap()
        let processing = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Processing HDR'")).firstMatch
        XCTAssertTrue(processing.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.buttons["camera.shutter"].isEnabled, "A second photo was admitted before saving")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        print("GLASSCAM-RETAINED-CHECKPOINT \(checkpoint)"); fflush(stdout)
        // A bounded checkpoint lets the host retain the actual journal/RAW as
        // evidence while production processing is suspended in the background.
        Thread.sleep(forTimeInterval: 15)
        if terminate { app.terminate(); app.launch() } else { app.activate() }
        let saved = savedStatus(app)
        XCTAssertTrue(saved.waitForExistence(timeout: 120), app.debugDescription)
        try waitForShutter(app)
        print("GLASSCAM-RECOVERY \(checkpoint) terminated=\(terminate) \(saved.label) elapsed-including-checkpoint=\(Date().timeIntervalSince(started))")
        app.buttons["camera.thumbnail"].tap()
        XCTAssertTrue(app.buttons["Share HDR photo"].waitForExistence(timeout: 10))
        let pixels = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Estimated source'")).firstMatch
        XCTAssertTrue(pixels.waitForExistence(timeout: 10))
        print("GLASSCAM-RESOLUTION \(checkpoint) \(pixels.label)")
        attach(app, name: "\(checkpoint)-recovered-photo")
        app.buttons["Camera"].tap()
    }

    private func readyCamera() throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.glasscam.prototype")
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        try waitForShutter(app)
        return app
    }

    private func selectLens(_ lens: String, in app: XCUIApplication) throws {
        app.buttons["camera.zoom"].tap()
        let stop = app.scrollViews.buttons["camera.zoom.\(lens)"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
        stop.tap()
        app.buttons["Viewfinder"].tap()
        try waitForShutter(app)
    }

    private func waitForShutter(_ app: XCUIApplication) throws {
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed, app.debugDescription)
    }

    private func savedStatus(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved HDR'")).firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
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
        XCTAssertTrue(app.buttons["Share HDR photo"].waitForExistence(timeout: 10), app.debugDescription)
        let whiteBalance = app.staticTexts["review.whiteBalance"]
        XCTAssertTrue(whiteBalance.waitForExistence(timeout: 10))
        XCTAssertTrue(whiteBalance.label.hasPrefix("Auto WB ·"), whiteBalance.label)
        print("GLASSCAM-AUTO-WB \(whiteBalance.label)")
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
