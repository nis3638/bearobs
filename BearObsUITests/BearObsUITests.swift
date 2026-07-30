import XCTest

@MainActor
final class BearObsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testProjectShellLaunches() {
        let application = XCUIApplication()
        application.launch()

        XCTAssertTrue(application.staticTexts["project-shell-title"].waitForExistence(timeout: 5))
    }
}
