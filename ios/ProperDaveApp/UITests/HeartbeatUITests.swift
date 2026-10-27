import XCTest

/// Drives the Advanced Settings heartbeat through the public UI:
/// toggle + all three sliders, idle silence, watching pings (observed via
/// the debug log's heartbeat_ping events), paused silence, and persisted
/// settings across relaunch.
final class HeartbeatUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        dismissNotificationPrompt()
    }

    private func dismissNotificationPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let dontAllow = springboard.buttons["Don’t Allow"]
        if dontAllow.waitForExistence(timeout: 3) { dontAllow.tap() }
    }

    private func goToAdvanced() {
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["Working heartbeat sound"]
        var attempts = 0
        while !toggle.exists && attempts < 8 {
            app.swipeUp()
            attempts += 1
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "heartbeat toggle not found")
    }

    private func pingCount() -> Int {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'heartbeat_ping'")).count
    }

    func testHeartbeatLifecycleThroughPublicUI() throws {
        // Enable + tune through Settings.
        goToAdvanced()
        let toggle = app.switches["Working heartbeat sound"]
        if toggle.value as? String == "0" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "1")

        for (label, position) in [("Heartbeat interval", 0.0), ("Heartbeat volume", 0.5), ("Heartbeat pitch", 0.2)] {
            let slider = app.sliders[label]
            var attempts = 0
            while !slider.exists && attempts < 8 { app.swipeUp(); attempts += 1 }
            XCTAssertTrue(slider.waitForExistence(timeout: 3), "\(label) slider not found")
            slider.adjust(toNormalizedSliderPosition: position)
        }

        // Idle silence: no pings before any watch starts.
        app.tabBars.buttons["Log"].tap()
        XCTAssertEqual(pingCount(), 0, "heartbeat must stay silent while idle")
        app.tabBars.buttons["Home"].tap()

        // Start the mock watch from the first example chip (sets the prompt
        // programmatically, so no keyboard can intercept the Start tap).
        let chip = app.buttons.matching(NSPredicate(format: "label CONTAINS 'elevator arrives'")).firstMatch
        var chipAttempts = 0
        while !chip.exists && chipAttempts < 8 { app.swipeUp(); chipAttempts += 1 }
        XCTAssertTrue(chip.waitForExistence(timeout: 3))
        chip.tap()
        let start = app.buttons["Start watching"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let watching = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Watching'")).firstMatch
        XCTAssertTrue(watching.waitForExistence(timeout: 5), "state never became Watching; hierarchy: \(app.debugDescription)")

        // Pings while watching (2 s interval: expect at least 2 in ~6 s).
        app.tabBars.buttons["Log"].tap()
        let deadline = Date().addingTimeInterval(10)
        while pingCount() < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThanOrEqual(pingCount(), 2, "expected repeated pings while watching")

        // Pause via debug-log sheet path: trigger modal -> View debug log.
        app.tabBars.buttons["Settings"].tap()
        let trigger = app.buttons["Trigger test critical error"]
        var attempts = 0
        while !trigger.exists && attempts < 8 { app.swipeUp(); attempts += 1 }
        XCTAssertTrue(trigger.waitForExistence(timeout: 3))
        trigger.tap()
        let viewLog = app.alerts.buttons["View debug log"]
        XCTAssertTrue(viewLog.waitForExistence(timeout: 3))
        viewLog.tap()
        // Filter to speech events so heartbeat_ping rows are the visible ones.
        let speechFilter = app.buttons["speech"]
        if speechFilter.waitForExistence(timeout: 3) { speechFilter.tap() }
        Thread.sleep(forTimeInterval: 1)
        let pausedCount = pingCount()
        Thread.sleep(forTimeInterval: 5)
        XCTAssertEqual(pingCount(), pausedCount, "heartbeat must stay silent while capture is paused")

        // Persistence across relaunch.
        app.terminate()
        app.launch()
        dismissNotificationPrompt()
        goToAdvanced()
        XCTAssertEqual(app.switches["Working heartbeat sound"].value as? String, "1",
                       "heartbeat toggle must persist")
        XCTAssertTrue(app.sliders["Heartbeat interval"].waitForExistence(timeout: 3),
                      "heartbeat sliders must persist with the toggle")
    }
}
