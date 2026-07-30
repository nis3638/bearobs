import XCTest

@testable import BearObs

final class BearObsTests: XCTestCase {
    func testApplicationModuleLoads() {
        XCTAssertEqual(String(describing: BearObsApp.self), "BearObsApp")
    }
}
