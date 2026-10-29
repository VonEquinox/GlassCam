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

    /// Simulator-only: manual diagnosis must work even when no camera can start.
    func testManualStateRecordsWithoutCameraOnSimulator() throws {
#if targetEnvironment(simulator)
        let app = makeApp(language: "zh-Hans")
        app.launch()
        let record = app.buttons["glass.record-state"]
        XCTAssertTrue(record.waitForExistence(timeout: 20))
        XCTAssertTrue(record.label.contains("记录状态"), record.label)
        app.buttons["glass.recordings"].tap()
        let entries = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "record-"))
        let previousRecords = Set(entries.allElementsBoundByIndex.map(\.label))
        app.navigationBars.buttons.firstMatch.tap()

        saveStateRecord(using: record)
        saveStateRecord(using: record)

        app.buttons["glass.recordings"].tap()
        let newRecords = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let latest = Set(entries.allElementsBoundByIndex.prefix(2).map(\.label))
            return latest.count == 2 && latest.isDisjoint(with: previousRecords)
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [newRecords], timeout: 15), .completed, app.debugDescription)
        let savedRecords = Set(entries.allElementsBoundByIndex.prefix(2).map(\.label))
        XCTAssertTrue(app.buttons["glass.export"].isEnabled)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["glass.recordings"].waitForExistence(timeout: 20))
        app.buttons["glass.recordings"].tap()
        XCTAssertEqual(Set(entries.allElementsBoundByIndex.prefix(2).map(\.label)), savedRecords)
#else
        throw XCTSkip("This check is intentionally restricted to a simulator.")
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

    private func saveStateRecord(using button: XCUIElement) {
        button.tap()
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
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
