import XCTest

/// iOS 只读客户端冒烟验收（REQ-004 / ADR-010）：每条测试用例自建临时 Vault，
/// 经 BEAROBS_AUTOPEN_VAULT 在启动时直接打开，不触碰设备上的真实数据。
@MainActor
final class BearObsIOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 首次启动显示 Vault 选择入口。
    func testLibraryEmptyStateLaunches() throws {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["open-vault-empty-state"]
                .waitForExistence(timeout: 10)
        )
    }

    /// AC-REQ-004-02/03：打开临时 Vault → 列表 → 阅读 → 返回；
    /// 阅读面不得出现任何编辑入口。
    func testSeededVaultOpensAndTheReaderStaysReadOnly() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "ReadOnlySmoke.md", content: "# 只读冒烟\n\n第一段。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        let list = application.descendants(matching: .any)["workspace-note-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The note list must be visible")

        let row = application.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "只读冒烟", "只读冒烟"
                )
            )
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Expected a row for 只读冒烟")
        row.tap()

        let reader = application.descendants(matching: .any)["reader-content"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The reader must open")
        XCTAssertEqual(
            application.descendants(matching: .any)
                .matching(identifier: "reader-edit-button").count,
            0,
            "The iOS reader must not present any edit entry"
        )

        application.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(
            list.waitForExistence(timeout: 10),
            "Popping back must return to the note list"
        )
    }

    /// AC-REQ-004-02：紧凑导航的五个固定入口都存在。
    func testCompactTabsExposeTheFixedEntries() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "TabsSmoke.md", content: "# 标签页冒烟\n\n正文。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        for title in ["笔记", "最近", "收藏", "搜索", "标签"] {
            XCTAssertTrue(
                application.tabBars.buttons[title].waitForExistence(timeout: 10),
                "Expected the \(title) tab"
            )
        }
    }

    /// 已打开 Vault 后仍需提供可见、可点击的切换入口。这个入口必须位于
    /// 紧凑宽度自己的 NavigationStack 内，不能依赖栈外不会显示的 toolbar。
    func testOpenedVaultExposesHittableOpenVaultAction() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "OpenVaultSmoke.md", content: "# Vault 切换冒烟\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        let list = application.descendants(matching: .any)["workspace-note-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The workspace must be visible")

        let openVault = application.descendants(matching: .any)["open-vault"]
        XCTAssertTrue(
            openVault.waitForExistence(timeout: 5),
            "An opened Vault must retain the switch-Vault action"
        )
        XCTAssertTrue(openVault.isHittable, "The switch-Vault action must be tappable")
        openVault.tap()

        // UIDocumentPickerViewController is exposed as an overlaid navigation
        // hierarchy rather than an XCTest `Sheet`. Its accessibility identifier
        // is stable and avoids assertions against localized system button labels.
        let documentPicker = application.navigationBars[
            "FullDocumentManagerViewControllerNavigationBar"
        ]
        XCTAssertTrue(
            documentPicker.waitForExistence(timeout: 5),
            "Tapping the action must present the system file-selection flow"
        )
        XCTAssertFalse(openVault.isHittable, "The picker must be modal over the workspace")
    }

    /// 大量标签必须处于真正的滚动容器中；末项可达，并向 VoiceOver 同时表达
    /// 完整层级与命中笔记数。
    func testTagListScrollsToLastNestedTagAndExposesItsCount() throws {
        let flatTags = (0..<40).map { String(format: "tag%02d", $0) }
        let tags = (flatTags + ["project/mobile"]).joined(separator: ", ")
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "ManyTags.md",
            content: "---\ntags: [\(tags)]\n---\n# 大量标签\n"
        )
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        try writeNote(
            named: "ParentOnly.md",
            content: "---\ntags: [project]\n---\n# 仅父级标签\n",
            in: temporaryRoot
        )
        application.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]

        application.launch()
        let tagsTab = application.tabBars.buttons["标签"]
        XCTAssertTrue(tagsTab.waitForExistence(timeout: 10), "The tags tab must exist")
        tagsTab.tap()

        let tagList = application.descendants(matching: .any)["workspace-tags-list"]
        XCTAssertTrue(tagList.waitForExistence(timeout: 10), "The tag list must load")

        let lastTag = application.descendants(matching: .any)["workspace-tag-project/mobile"]
        for _ in 0..<20 where !lastTag.isHittable {
            tagList.swipeUp()
        }

        XCTAssertTrue(lastTag.isHittable, "The last nested tag must be reachable by scrolling")
        XCTAssertEqual(lastTag.label, "project/mobile，1 篇笔记")
        lastTag.tap()

        let taggedNotes = application.descendants(matching: .any)["workspace-tag-note-list"]
        XCTAssertTrue(
            taggedNotes.waitForExistence(timeout: 10),
            "Tapping a nested tag must open its exact-match note list"
        )
        let matchingNote = noteRow(titled: "大量标签", in: application)
        XCTAssertTrue(matchingNote.waitForExistence(timeout: 10))
        XCTAssertFalse(
            noteRow(titled: "仅父级标签", in: application).exists,
            "A child tag must not include notes tagged only with its parent"
        )

        taggedNotes.swipeDown()
        XCTAssertTrue(taggedNotes.waitForExistence(timeout: 10))
        XCTAssertTrue(
            noteRow(titled: "大量标签", in: application).waitForExistence(timeout: 10),
            "The exact-match list must remain usable after pull-to-refresh"
        )
    }

    // MARK: - Seeded-vault helpers

    /// 与 AppDirectories.autoOpenVaultEnvironmentKey 对应（UI 测试目标不链接
    /// 应用模块，故以字面量引用）。
    private static let autoOpenVaultEnvironmentKey = "BEAROBS_AUTOPEN_VAULT"

    private func makeSeededApplication(
        noteNamed name: String, content: String
    ) throws -> (application: XCUIApplication, temporaryRoot: URL) {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        let vault = temporaryRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault, withIntermediateDirectories: true)
        try writeNote(named: name, content: content, in: temporaryRoot)
        application.launchEnvironment[Self.autoOpenVaultEnvironmentKey] = vault.path
        return (application, temporaryRoot)
    }

    private func writeNote(
        named name: String,
        content: String,
        in temporaryRoot: URL
    ) throws {
        let note =
            temporaryRoot
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent(name)
        try content.write(to: note, atomically: true, encoding: .utf8)
    }

    private func noteRow(titled title: String, in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    title, title
                )
            )
            .firstMatch
    }

    /// 每条测试使用独立临时根目录承载全部本地状态。
    private func makeIsolatedApplication() throws -> (
        application: XCUIApplication,
        temporaryRoot: URL
    ) {
        let temporaryRoot = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent("BearObsIOSUITests-\(UUID().uuidString)", isDirectory: true)
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
}
