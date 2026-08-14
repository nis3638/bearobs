import XCTest

@MainActor
final class BearObsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLibraryEmptyStateLaunches() {
        let application = XCUIApplication()
        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["library-empty"].waitForExistence(timeout: 5)
        )
    }
}
