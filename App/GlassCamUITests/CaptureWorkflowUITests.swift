import XCTest
import Darwin
import AVFoundation
import UIKit

/// Opt-in physical-device acceptance: capture tests save real photos to the system library.
/// Run only the GlassCamCaptureTests scheme when this side effect is intended.
final class CaptureWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// UI policy only: no camera capture and no Photos writes.
    func testCapturePriorityMenuAndSpeed12MPOnSimulator() throws {
#if targetEnvironment(simulator)
        let app = makeApp()
        app.launchArguments += ["-camera.output.preferred.v2", "24"]
        addUIInterruptionMonitor(withDescription: "Simulator camera permission") { alert in
            for title in ["Don't Allow", "Don’t Allow", "不允许"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launch()
        let priority = app.buttons["camera.quality"]
        XCTAssertTrue(priority.waitForExistence(timeout: 20))
        priority.tap()
        let speed = app.buttons["camera.quality.speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 5), app.debugDescription)
        speed.tap()
        XCTAssertEqual(priority.value as? String, "Speed")
        XCTAssertEqual(app.buttons["camera.resolution"].value as? String, "12 MP")
        app.terminate(); app.launch()
        XCTAssertTrue(priority.waitForExistence(timeout: 20))
        XCTAssertEqual(priority.value as? String, "Speed")
        priority.tap(); app.buttons["camera.quality.balanced"].tap()
        XCTAssertEqual(priority.value as? String, "Balanced")
        XCTAssertEqual(app.buttons["camera.resolution"].value as? String, "24 MP")
        priority.tap(); app.buttons["camera.quality.quality"].tap()
        XCTAssertEqual(priority.value as? String, "Quality")
        attach(app, name: "Capture-priority-menu")
#else
        throw XCTSkip("This check is intentionally restricted to a simulator.")
#endif
    }

    func testCompactControlsCanReopenAfterDismissalOnSimulator() throws {
#if targetEnvironment(simulator)
        let app = makeApp()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let controls = app.buttons["Open camera controls"]
        XCTAssertTrue(controls.waitForExistence(timeout: 20))
        controls.tap()
        let back = app.buttons["camera.panel.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(back.waitForNonExistence(timeout: 10))
        controls.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10))
#else
        throw XCTSkip("This check is restricted to a simulator.")
#endif
    }

    /// Simulator-only: manual diagnosis must work even when no camera can start.
    func testManualStateRecordsWithoutCameraOnSimulator() throws {
#if targetEnvironment(simulator)
        let app = makeApp(language: "zh-Hans")
        addUIInterruptionMonitor(withDescription: "Simulator camera permission") { alert in
            for title in ["不允许", "Don't Allow", "Don’t Allow"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launch()
        let record = app.buttons["glass.record-state"]
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        XCTAssertTrue(record.label.contains("记录状态"), record.label)
        attach(app, name: "Manual-record-button-Chinese")
        for _ in 0..<2 {
            record.tap()
            let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: record)
            XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
        }
        app.buttons["glass.recordings"].tap()
        let entries = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "record-"))
        let count = XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in entries.count >= 2 }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [count], timeout: 15), .completed, app.debugDescription)
        XCTAssertTrue(app.buttons["glass.export"].isEnabled)
        attach(app, name: "Manual-records-saved-without-camera")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["glass.recordings"].waitForExistence(timeout: 20))
        app.buttons["glass.recordings"].tap()
        XCTAssertGreaterThanOrEqual(entries.count, 2)
#else
        throw XCTSkip("This check is intentionally restricted to a simulator.")
#endif
    }

    /// Inspect the current full interface, including the glass behind controls.
    /// This targeted diagnostic never presses the shutter or changes settings.
    func testPeripheralGlassPreviewOnly() throws {
        let app = XCUIApplication(bundleIdentifier: "dev.glasscam.prototype")
        app.activate()
        XCTAssertTrue(app.otherElements["camera.photo.frame"].waitForExistence(timeout: 30))
        let settled = expectation(description: "Allow the peripheral animation to settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        attach(app, name: "Peripheral-glass-full-interface")
        print("GLASSCAM-PERIPHERAL-UI \(app.debugDescription)")
    }

    /// Reproduce physical-camera handoffs without triggering a still capture.
    /// Check readiness after every switch so returning to Main cannot conceal
    /// an Ultra Wide / Telephoto session that failed to start.
    func testPreviewLensSwitchesRemainReady() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = makeApp()
        app.launchEnvironment["OS_ACTIVITY_DT_MODE"] = "YES"
        app.launchEnvironment["GLASSCAM_PERIPHERAL_TRACE"] = "1"
        app.launch()
        try waitForShutter(app)
        for lens in ["Ultra Wide", "Main", "Telephoto", "Main", "Ultra Wide", "Main"] {
            app.buttons["camera.zoom"].tap()
            let stop = app.scrollViews.buttons["camera.zoom.\(lens)"]
            XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
            stop.tap()
            app.buttons["camera.panel.back"].tap()
            try waitForShutter(app)
            print("GLASSCAM-PREVIEW-SWITCH ready=\(lens)")
        }
        attach(app, name: "Preview-lens-switches-ready")
    }

    func testSettingsAndAutomatic24MPSave() throws {
        try checkCapture(outputs: [24], review: false)
    }

    func testSettingsAndAutomatic48MPSaveAndReview() throws {
        try checkCapture(outputs: [48], review: true)
    }

    /// Exercises the new controls without adding extra test photos. Physical
    /// source, RAW framing and image quality remain separate device checks.
    func testThreeLensShortcutsAndContinuousRuler() throws {
        let app = makeApp()
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
        app.buttons["camera.panel.back"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed,
                       "Zoom changes left the shutter disabled")
    }

    /// Layout and localization checks open the camera but never press the shutter.
    func testPhotoFrameAndControlsInPortraitAndLandscape() throws {
        let app = try readyCamera()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let frame = app.otherElements["camera.photo.frame"]
            XCTAssertTrue(frame.waitForExistence(timeout: 15))
            let expectedPortrait = orientation == .portrait
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (app.frame.height > app.frame.width) == expectedPortrait &&
                    (frame.frame.height > frame.frame.width) == expectedPortrait
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 15), .completed)
            try waitForShutter(app)
            let window = app.frame, photo = frame.frame
            let aspect: CGFloat = expectedPortrait ? 3.0/4.0 : 4.0/3.0
            let expectedWidth = min(window.width, window.height*aspect)
            XCTAssertEqual(photo.width, expectedWidth, accuracy: 1)
            XCTAssertEqual(photo.height, expectedWidth/aspect, accuracy: 1)
            XCTAssertEqual(photo.midX, window.midX, accuracy: 1)
            XCTAssertEqual(photo.midY, window.midY, accuracy: 1)
            for identifier in ["camera.resolution", "camera.style", "camera.zoom", "camera.shutter",
                               "camera.thumbnail", "camera.settings", "camera.grid", "capture.status.summary"] {
                let control = app.buttons[identifier]
                XCTAssertTrue(control.exists, identifier)
                XCTAssertGreaterThanOrEqual(control.frame.width, 43.5, identifier)
                XCTAssertGreaterThanOrEqual(control.frame.height, 43.5, identifier)
                let intersection = control.frame.intersection(photo)
                XCTAssertTrue(intersection.isNull || intersection.width*intersection.height < 0.5,
                              "\(identifier) covers the photograph")
            }
            attach(app, name: expectedPortrait ? "Glass-viewfinder-portrait" : "Glass-viewfinder-landscape")
        }
    }

    func testChineseQuickControlsAndSettingsPages() throws {
        let app = try readyCamera(language: "zh-Hans")
        XCTAssertEqual(app.buttons["camera.settings"].label, "相机设置与照片效果")
        XCTAssertEqual(app.buttons["camera.resolution"].label, "照片分辨率")
        let resolution = app.buttons["camera.resolution"]
        let before = resolution.value as? String
        resolution.tap()
        XCTAssertNotEqual(resolution.value as? String, before)
        resolution.tap()
        XCTAssertEqual(resolution.value as? String, before)
        let grid = app.buttons["camera.grid"]
        let wasVisible = grid.value as? String
        grid.tap()
        XCTAssertNotEqual(grid.value as? String, wasVisible)
        grid.tap()
        attach(app, name: "Glass-viewfinder-Chinese")

        app.buttons["camera.style"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "照片风格").firstMatch.waitForExistence(timeout: 10))
        app.segmentedControls.buttons["HNCS"].tap()
        XCTAssertFalse(app.buttons["Square Crop"].exists)
        attach(app, name: "Photo-styles-Chinese")
        app.buttons["camera.panel.back"].tap()
        app.buttons["camera.settings"].tap()
        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["settings.resolution"].exists)
        XCTAssertFalse(app.switches["effects.extraCrop"].exists)
        attach(app, name: "Common-settings-Chinese")
        let advanced = app.buttons["settings.advanced"]
        for _ in 0..<6 {
            if advanced.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(advanced.isHittable)
        advanced.tap()
        XCTAssertTrue(app.staticTexts["高级设置"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["settings.back"].label, "返回设置")
        attach(app, name: "Advanced-settings-Chinese")
        app.buttons["settings.back"].tap()
        XCTAssertEqual(app.buttons["settings.back"].label, "返回相机")
        app.buttons["settings.back"].tap()
        try waitForShutter(app)
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
        print("GLASSCAM-LANDSCAPE \(saved.value as? String ?? saved.label)")
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
        let processing = app.buttons.matching(NSPredicate(format:
            "identifier == 'capture.status.summary' AND label == 'Processing photo'")).firstMatch
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
        print("GLASSCAM-RECOVERY \(checkpoint) terminated=\(terminate) \(saved.value as? String ?? saved.label) elapsed-including-checkpoint=\(Date().timeIntervalSince(started))")
        app.buttons["camera.thumbnail"].tap()
        XCTAssertTrue(app.buttons["Share HDR photo"].waitForExistence(timeout: 10))
        let pixels = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Estimated source'")).firstMatch
        XCTAssertTrue(pixels.waitForExistence(timeout: 10))
        print("GLASSCAM-RESOLUTION \(checkpoint) \(pixels.label)")
        attach(app, name: "\(checkpoint)-recovered-photo")
        app.buttons["Camera"].tap()
    }

    private func makeApp(language: String = "en") -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.glasscam.prototype")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        return app
    }

    private func readyCamera(language: String = "en") throws -> XCUIApplication {
        let app = makeApp(language: language)
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        try waitForShutter(app)
        return app
    }

    private func selectLens(_ lens: String, in app: XCUIApplication) throws {
        app.buttons["camera.zoom"].tap()
        let stop = app.scrollViews.buttons["camera.zoom.\(lens)"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
        stop.tap()
        app.buttons["camera.panel.back"].tap()
        try waitForShutter(app)
    }

    private func waitForShutter(_ app: XCUIApplication) throws {
        let shutter = app.buttons["camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: shutter)], timeout: 30), .completed, app.debugDescription)
    }

    private func savedStatus(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format:
            "identifier == 'capture.status.summary' AND label == 'Saved to Photos'")).firstMatch
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func checkCapture(outputs: [Int], review: Bool) throws {
        let app = makeApp()
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
            let permissionOrSave = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                springboard.alerts.firstMatch.exists || self.savedStatus(app).exists
            }, object: app)
            _ = XCTWaiter.wait(for: [permissionOrSave], timeout: 20)
            if springboard.alerts.firstMatch.exists {
                for label in ["Allow Adding Photos", "允许添加照片", "允许添加", "Allow", "允许"] {
                    if springboard.alerts.buttons[label].exists { springboard.alerts.buttons[label].tap(); break }
                }
            }
            let saved = savedStatus(app)
            XCTAssertTrue(saved.waitForExistence(timeout: 100), app.debugDescription)
            XCTAssertTrue(app.buttons["camera.shutter"].exists, "Capture navigated away from camera")
            XCTAssertTrue(app.buttons["camera.thumbnail"].isEnabled)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Saved-\(megapixels)MP-HDR"; attachment.lifetime = .keepAlways
            add(attachment)
            print("GLASSCAM-ACCEPTANCE \(megapixels)MP \(saved.value as? String ?? saved.label)")
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
