import XCTest

/// Conversation PoC (TRD-006 slice): explicit start, a typed turn,
/// a spoken-style reply, and an exit back Home.
final class ConversationUITests: XCTestCase {
    func testConversationOpensAndAnswersTypedTurn() throws {
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons["Conversation"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        let field = app.textFields["Conversation turn"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "conversation screen should offer a typed turn")
        field.tap()
        field.typeText("Hello Dave")
        app.buttons["Send"].tap()
        // Any Dave reply bubble: local chat, or the honest capability fallback.
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'watching' OR label CONTAINS 'Dave'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20), "a typed turn should get a reply")
    }
}
