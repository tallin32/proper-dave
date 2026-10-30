import XCTest

/// The goal field (and every text field) must offer an explicit way to
/// dismiss the keyboard: the Done button above it.
final class KeyboardUITests: XCTestCase {
    func testGoalFieldDoneButtonDismissesKeyboard() throws {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["Goal prompt"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Tell me when the elevator arrives")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "keyboard should be up while editing the goal")
        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5),
                      "keyboard toolbar should offer Done")
        done.tap()
        XCTAssertFalse(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                       "Done should dismiss the keyboard")
        XCTAssertTrue((field.value as? String ?? "").contains("Tell me when the elevator arrives"),
                      "dismissing must not lose the typed goal")
    }
}
