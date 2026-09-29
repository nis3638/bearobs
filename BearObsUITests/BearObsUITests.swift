import XCTest

@MainActor
final class BearObsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLibraryEmptyStateLaunches() throws {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["open-vault-empty-state"]
                .waitForExistence(timeout: 5)
        )
    }

    func testLibraryRemainsOperableAtLargestAccessibilitySizeInDarkMode() throws {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-AppleInterfaceStyle",
            "Dark",
        ]
        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["open-vault-empty-state"]
                .waitForExistence(timeout: 5)
        )
    }

    /// 每条测试使用独立临时根目录承载全部本地状态，
    /// 不读取也不写入开发者机器上一次选择的 Vault。
    private func makeIsolatedApplication() throws -> (
        application: XCUIApplication,
        temporaryRoot: URL
    ) {
        let temporaryRoot = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("BearObsUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )

        let application = XCUIApplication()
        application.launchEnvironment["BEAROBS_APP_SUPPORT_ROOT"] = temporaryRoot.path
        return (application, temporaryRoot)
    }

    private func cleanUp(application: XCUIApplication, temporaryRoot: URL) {
        application.terminate()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private func assertHittableNavigationItem(
        _ label: String,
        in application: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let candidates = [
            application.buttons[label],
            application.radioButtons[label],
            application.descendants(matching: .any)[label],
        ]
        XCTAssertTrue(
            candidates.contains { $0.exists && $0.isHittable },
            "Expected a hittable navigation item named \(label)",
            file: file,
            line: line
        )
    }
}
