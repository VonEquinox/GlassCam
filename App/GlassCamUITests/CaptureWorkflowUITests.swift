import XCTest

final class CaptureWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testSpeedSelectionPersistsOnSimulator() throws {
        try checkPriorityPersistence(quality: "speed", title: "Speed", output: "24 MP")
    }

    func testBalancedSelectionPersistsOnSimulator() throws {
        try checkPriorityPersistence(quality: "balanced", title: "Balanced", output: "24 MP")
    }

    func testPriorityMenuOnlyOffersSpeedAndBalancedOnSimulator() throws {
#if targetEnvironment(simulator)
        let app = makeApp()
        app.launch()
        let priority = app.buttons["camera.quality"]
        XCTAssertTrue(priority.waitForExistence(timeout: 20))
        priority.tap()
        XCTAssertTrue(app.buttons["camera.quality.speed"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["camera.quality.balanced"].exists)
        XCTAssertFalse(app.buttons["camera.quality.quality"].exists)
#else
        throw XCTSkip("This check is restricted to a simulator.")
#endif
    }

    private func checkPriorityPersistence(quality: String, title: String, output: String) throws {
#if targetEnvironment(simulator)
        let app = makeApp()
        app.launch()
        let priority = app.buttons["camera.quality"]
        let initialQuality = quality == "speed" ? "balanced" : "speed"
        let initialTitle = quality == "speed" ? "Balanced" : "Speed"
        selectPriority(initialQuality, in: app)
        app.terminate()
        app.launch()
        XCTAssertTrue(priority.waitForExistence(timeout: 20))
        XCTAssertEqual(priority.value as? String, initialTitle)

        selectPriority(quality, in: app)
        app.terminate()
        app.launch()

        XCTAssertTrue(priority.waitForExistence(timeout: 20))
        XCTAssertEqual(priority.value as? String, title)
        let resolution = app.otherElements["camera.resolution"]
        XCTAssertTrue(resolution.exists)
        XCTAssertEqual(resolution.value as? String, output)
#else
        throw XCTSkip("This check is restricted to a simulator.")
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

    func testRAWRecordingActionsAppearInAdvancedSettingsOnSimulator() throws {
#if targetEnvironment(simulator)
        let app = makeApp()
        app.launch()
        let settings = app.buttons["camera.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        XCTAssertFalse(app.buttons["settings.raw.record11"].exists)
        let advanced = app.buttons["settings.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 10))
        advanced.tap()
        let samples = app.buttons["settings.raw.record11"]
        let scene = app.buttons["settings.raw.recordScene"]
        XCTAssertTrue(samples.waitForExistence(timeout: 10))
        XCTAssertTrue(scene.exists)
#else
        throw XCTSkip("This check is restricted to a simulator.")
#endif
    }

    func testPortraitFilterDialCanSwitchEngineAndCloseOnSimulator() throws {
#if targetEnvironment(simulator)
        let app = makeApp()
        app.launch()
        let style = app.buttons["camera.style"]
        XCTAssertTrue(style.waitForExistence(timeout: 20))
        style.tap()
        let engine = app.buttons["camera.dial.engine.ffcs"]
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        engine.tap()
        app.buttons["camera.dial.close"].tap()
        XCTAssertTrue(engine.waitForNonExistence(timeout: 5))
#else
        throw XCTSkip("This check is restricted to a simulator.")
#endif
    }

    private func selectPriority(_ quality: String, in app: XCUIApplication) {
        let priority = app.buttons["camera.quality"]
        XCTAssertTrue(priority.waitForExistence(timeout: 20))
        priority.tap()
        let choice = app.buttons["camera.quality.\(quality)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
    }

    private func makeApp(language: String = "en") -> XCUIApplication {
        addUIInterruptionMonitor(withDescription: "Simulator camera permission") { alert in
            for title in ["Don't Allow", "Don’t Allow", "不允许"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        let app = XCUIApplication(bundleIdentifier: "dev.glasscam.prototype")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "en" ? "en_US" : "zh_CN"]
        return app
    }
}
