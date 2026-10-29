import XCTest

final class CaptureWorkflowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testF5SelectionPersistsOnSimulator() throws {
        try checkPriorityPersistence(quality: "f5", title: "F5", output: "2× sampling")
    }

    func testBalancedSelectionPersistsOnSimulator() throws {
        try checkPriorityPersistence(quality: "balanced", title: "Balanced", output: "24 MP")
    }

    func testQualitySelectionPersistsOnSimulator() throws {
        try checkPriorityPersistence(quality: "quality", title: "Quality", output: "24 MP")
    }

    private func checkPriorityPersistence(quality: String, title: String, output: String) throws {
#if targetEnvironment(simulator)
        let app = makeApp()
        app.launchArguments += ["-camera.output.preferred.v2", "24"]
        app.launch()
        let priority = app.buttons["camera.quality"]
        let initialQuality = quality == "quality" ? "balanced" : "quality"
        let initialTitle = quality == "quality" ? "Balanced" : "Quality"
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
        XCTAssertEqual(app.buttons["camera.resolution"].value as? String, output)
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
