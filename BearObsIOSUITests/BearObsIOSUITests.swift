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

    /// AC-REQ-004-02/05：搜索结果可进入阅读，收藏跨重启持久化；整个流程
    /// 只能写 App 自己的用户状态，Vault 内所有 Markdown 字节必须保持不变。
    func testSearchFavoriteAndRelaunchKeepVaultBytesUnchanged() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "Needle.md",
            content: "# 可搜索笔记\n\nunique-search-token\n"
        )
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        try writeNote(
            named: "Other.md",
            content: "# 其它笔记\n\n没有目标词。\n",
            in: temporaryRoot
        )
        let vault = temporaryRoot.appendingPathComponent("Vault", isDirectory: true)
        let before = try markdownBytes(in: vault)

        application.launch()
        let searchTab = application.tabBars.buttons["搜索"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()

        let search = application.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("unique-search-token")

        let result = noteRow(titled: "可搜索笔记", in: application)
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertFalse(noteRow(titled: "其它笔记", in: application).exists)
        result.tap()

        let favorite = application.buttons.matching(
            identifier: "reader-favorite-button"
        ).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        XCTAssertTrue(favorite.isEnabled)
        favorite.tap()
        let favoriteSaved = NSPredicate(
            format: "label == %@ AND isEnabled == true",
            "取消收藏"
        )
        expectation(for: favoriteSaved, evaluatedWith: favorite)
        waitForExpectations(timeout: 10)

        application.terminate()
        application.launch()
        let favoritesTab = application.tabBars.buttons["收藏"]
        XCTAssertTrue(favoritesTab.waitForExistence(timeout: 10))
        favoritesTab.tap()
        XCTAssertTrue(noteRow(titled: "可搜索笔记", in: application).waitForExistence(timeout: 10))

        XCTAssertEqual(try markdownBytes(in: vault), before)
    }

    /// AC-REQ-004-03：已解析 Wiki Link 在紧凑导航栈内推入目标 Reader。
    func testResolvedWikiLinkNavigatesToTheTargetReader() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "Source.md",
            content: "# 来源\n\n打开 [[Target|目标笔记]]。\n"
        )
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        try writeNote(
            named: "Target.md",
            content: "# Wiki 目标\n\n到达目标正文。\n",
            in: temporaryRoot
        )

        application.launch()
        let source = noteRow(titled: "来源", in: application)
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.tap()

        let link = application.descendants(matching: .any)["reader-inline-link"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertEqual(link.label, "链接：目标笔记")
        link.tap()

        XCTAssertTrue(application.navigationBars["Wiki 目标"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            application.descendants(matching: .any)["reader-content"]
                .waitForExistence(timeout: 10)
        )
    }

    /// AC-REQ-004-07：最大辅助字号和深色模式下核心入口仍可访问。
    func testCompactWorkspaceRemainsOperableAtLargestTypeInDarkMode() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "Accessible.md",
            content: "# 可访问阅读\n\n正文。\n"
        )
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        application.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle",
            "Dark",
        ]

        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["workspace-note-list"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(application.tabBars.buttons["标签"].isHittable)
        XCTAssertTrue(application.descendants(matching: .any)["open-vault"].isHittable)
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

    private func markdownBytes(in vault: URL) throws -> [String: Data] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: vault,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            throw CocoaError(.fileReadUnknown)
        }
        var bytes: [String: Data] = [:]
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, file.pathExtension.lowercased() == "md" else {
                continue
            }
            let relativePath = String(file.path.dropFirst(vault.path.count + 1))
            bytes[relativePath] = try Data(contentsOf: file)
        }
        return bytes
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
