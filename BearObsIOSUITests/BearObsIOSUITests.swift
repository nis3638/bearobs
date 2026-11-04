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

    /// AC-REQ-005-01 / AC-REQ-004-02/03：打开临时 Vault → 卡片流 → 阅读 → 返回；
    /// 首页是卡片流而不是旧的笔记列表入口，阅读面不得出现任何编辑入口。
    func testSeededVaultOpensAndTheReaderStaysReadOnly() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "ReadOnlySmoke.md", content: "# 只读冒烟\n\n第一段。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        let feed = application.descendants(matching: .any)["card-feed-list"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "The card feed must be visible")
        XCTAssertEqual(
            application.descendants(matching: .any)
                .matching(identifier: "workspace-note-list").count,
            0,
            "The compact home must not fall back to the old note-list entry"
        )

        let card = noteRow(titled: "只读冒烟", in: application)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Expected a card for 只读冒烟")
        card.tap()

        let reader = application.descendants(matching: .any)["reader-content"]
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "The reader must open")
        XCTAssertEqual(
            application.descendants(matching: .any)
                .matching(identifier: "reader-edit-button").count,
            0,
            "The iOS reader must not present any edit entry"
        )

        application.navigationBars.buttons["BackButton"].tap()

        XCTAssertTrue(
            feed.waitForExistence(timeout: 10),
            "Popping back must return to the card feed"
        )
    }

    /// AC-REQ-005-01：紧凑导航只保留三个固定入口（笔记 / 回顾 / 标签），
    /// 「最近」「收藏」不再出现在紧凑宽度顶级入口。
    func testCompactTabsExposeTheFixedEntries() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "TabsSmoke.md", content: "# 标签页冒烟\n\n正文。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        for title in ["笔记", "回顾", "标签"] {
            XCTAssertTrue(
                application.tabBars.buttons[title].waitForExistence(timeout: 10),
                "Expected the \(title) tab"
            )
        }
        XCTAssertEqual(application.tabBars.buttons.count, 3, "Compact width keeps exactly three entries")
        for removed in ["ios-tab-recent", "ios-tab-favorites"] {
            XCTAssertEqual(
                application.descendants(matching: .any)
                    .matching(identifier: removed).count,
                0,
                "\(removed) must not exist in the compact navigation"
            )
        }

        application.tabBars.buttons["回顾"].tap()
        XCTAssertTrue(
            application.descendants(matching: .any)["review-root"]
                .waitForExistence(timeout: 10),
            "The review entry must present its root view"
        )
    }

    /// FR-002：规则确认后展示当日批次；点批次行推入与卡片流相同的阅读面，
    /// 且 iOS 阅读面不出现任何编辑入口。返回后批次仍在。
    func testReviewBatchRowOpensTheReader() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "冒烟笔记.md", content: "# 冒烟标题\n\n第一段正文。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        application.tabBars.buttons["回顾"].tap()
        let done = application.descendants(matching: .any)["review-rule-done"]
        XCTAssertTrue(
            done.waitForExistence(timeout: 10),
            "First entry must present the rule editor once loading finishes"
        )
        done.tap()

        let row = application.descendants(matching: .any)["review-batch-row-冒烟笔记.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Expected the drawn batch row")
        row.tap()

        let reader = application.descendants(matching: .any)["reader-content"]
        XCTAssertTrue(
            reader.waitForExistence(timeout: 10),
            "The batch row must push the reader"
        )
        XCTAssertEqual(
            application.descendants(matching: .any)
                .matching(identifier: "reader-edit-button").count,
            0,
            "The reader opened from review must not present any edit entry"
        )

        application.navigationBars.buttons["BackButton"].tap()

        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "Popping back must return to the review batch"
        )
    }

    /// FR-001.3 / FR-001.5 / FR-003：卡片展示标题、5 个标签取 3 加「+2」、
    /// 失败笔记显示固定文案；点卡片上的标签按完整身份精确过滤，可清除。
    func testCardFeedFiltersByTappedTagAndShowsFixedCopyForFailedNotes() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "项目计划.md",
            content: "---\ntags: [project, t1, t2, t3, t4]\n---\n# 项目计划\n\n第一段正文。\n"
        )
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        try writeNote(
            named: "移动端.md",
            content: "---\ntags: [project/mobile]\n---\n# 移动端\n\n只有子标签。\n",
            in: temporaryRoot
        )
        try writeNote(named: "其他.md", content: "# 其他笔记\n\n正文。\n", in: temporaryRoot)
        try Data([0xFF, 0x00, 0x01]).write(
            to: temporaryRoot.appendingPathComponent("Vault/Broken.md")
        )

        application.launch()

        let feed = application.descendants(matching: .any)["card-feed-list"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "The card feed must be visible")

        XCTAssertTrue(noteRow(titled: "项目计划", in: application).waitForExistence(timeout: 10))
        XCTAssertTrue(noteRow(titled: "移动端", in: application).waitForExistence(timeout: 10))
        XCTAssertTrue(noteRow(titled: "其他笔记", in: application).waitForExistence(timeout: 10))
        // FR-001.5：失败笔记仍占一个卡片位置，摘要处显示固定文案。
        XCTAssertTrue(
            application.staticTexts["这条笔记暂时无法读取"].waitForExistence(timeout: 10),
            "The failed note must degrade to the fixed copy"
        )
        // FR-001.3：5 个标签展示 3 个，其余折为「+N」。
        XCTAssertTrue(
            application.staticTexts["+2"].waitForExistence(timeout: 10),
            "The fifth and sixth tags must fold into +2"
        )

        // FR-003.1/2：点卡片上的标签，按完整标签身份精确过滤。
        let projectChip = application.descendants(matching: .any)["card-tag-project"].firstMatch
        XCTAssertTrue(projectChip.waitForExistence(timeout: 10))
        projectChip.tap()

        XCTAssertTrue(
            application.descendants(matching: .any)["card-feed-filter-bar"]
                .waitForExistence(timeout: 10),
            "An active filter must be announced by the filter bar"
        )
        XCTAssertTrue(noteRow(titled: "项目计划", in: application).waitForExistence(timeout: 10))
        XCTAssertFalse(
            noteRow(titled: "移动端", in: application).exists,
            "Filtering project must not include notes tagged only project/mobile"
        )
        XCTAssertFalse(noteRow(titled: "其他笔记", in: application).exists)

        // FR-003.3：过滤可清除，清除后回到全部。
        let clear = application.descendants(matching: .any)["card-feed-filter-clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        XCTAssertTrue(noteRow(titled: "移动端", in: application).waitForExistence(timeout: 10))
        XCTAssertTrue(noteRow(titled: "其他笔记", in: application).waitForExistence(timeout: 10))
    }

    /// FR-001.1：空 Vault 显示卡片流的空状态，不出现旧笔记列表。
    func testCardFeedEmptyVaultShowsEmptyState() throws {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        let vault = temporaryRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        application.launchEnvironment[Self.autoOpenVaultEnvironmentKey] = vault.path

        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["card-feed-empty"]
                .waitForExistence(timeout: 10),
            "An empty vault must show the card feed empty state"
        )
        XCTAssertEqual(
            application.descendants(matching: .any)
                .matching(identifier: "workspace-note-list").count,
            0,
            "The old note-list entry must not reappear for empty vaults"
        )
    }

    /// 已打开 Vault 后仍需提供可见、可点击的切换入口。这个入口必须位于
    /// 紧凑宽度自己的 NavigationStack 内，不能依赖栈外不会显示的 toolbar。
    func testOpenedVaultExposesHittableOpenVaultAction() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "OpenVaultSmoke.md", content: "# Vault 切换冒烟\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()

        let feed = application.descendants(matching: .any)["card-feed-list"]
        XCTAssertTrue(feed.waitForExistence(timeout: 10), "The workspace must be visible")

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

    /// M-IOS-5.12：切换到第二个 Vault 后必须重建工作区，不能复用第一个
    /// Vault 的索引或收藏；重启恢复第二个 Vault，两个 Vault 均保持只读。
    func testSwitchingVaultsKeepsIndexesAndFavoritesIsolated() throws {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        let vaultA = temporaryRoot.appendingPathComponent("Vault-A", isDirectory: true)
        let vaultB = temporaryRoot.appendingPathComponent("Vault-B", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vaultB, withIntermediateDirectories: true)
        try writeNote(named: "Shared.md", content: "# Vault A\n", inVault: vaultA)
        try writeNote(named: "Shared.md", content: "# Vault B\n", inVault: vaultB)
        let beforeA = try markdownBytes(in: vaultA)
        let beforeB = try markdownBytes(in: vaultB)
        application.launchEnvironment[Self.autoOpenVaultEnvironmentKey] = vaultA.path
        application.launchEnvironment[Self.importVaultEnvironmentKey] = vaultB.path

        application.launch()
        let vaultARow = noteRow(titled: "Vault A", in: application)
        XCTAssertTrue(vaultARow.waitForExistence(timeout: 10))
        vaultARow.tap()
        let favorite = application.buttons.matching(
            identifier: "reader-favorite-button"
        ).firstMatch
        XCTAssertTrue(favorite.waitForExistence(timeout: 10))
        favorite.tap()
        application.navigationBars.buttons.firstMatch.tap()

        application.descendants(matching: .any)["open-vault"].tap()

        XCTAssertTrue(noteRow(titled: "Vault B", in: application).waitForExistence(timeout: 10))
        XCTAssertFalse(noteRow(titled: "Vault A", in: application).exists)

        // 收藏按 Vault 隔离：Vault B 的同名笔记不得显示 Vault A 的收藏状态
        // （紧凑宽度的「收藏」顶级入口已被 REQ-005 移除，改由阅读面按钮断言）。
        noteRow(titled: "Vault B", in: application).tap()
        let vaultBFavorite = application.buttons.matching(
            identifier: "reader-favorite-button"
        ).firstMatch
        XCTAssertTrue(vaultBFavorite.waitForExistence(timeout: 10))
        let notFavorited = NSPredicate(format: "label == %@ AND isEnabled == true", "收藏")
        expectation(for: notFavorited, evaluatedWith: vaultBFavorite)
        waitForExpectations(timeout: 10)
        application.navigationBars.buttons.firstMatch.tap()

        application.terminate()
        application.launchEnvironment.removeValue(forKey: Self.autoOpenVaultEnvironmentKey)
        application.launchEnvironment.removeValue(forKey: Self.importVaultEnvironmentKey)
        application.launch()
        XCTAssertTrue(noteRow(titled: "Vault B", in: application).waitForExistence(timeout: 10))
        XCTAssertEqual(try markdownBytes(in: vaultA), beforeA)
        XCTAssertEqual(try markdownBytes(in: vaultB), beforeB)
    }

    /// M-IOS-5.12：第二个 Vault 无法打开时，旧工作区和磁盘中的当前选择
    /// 都必须保持不变；错误文案不得泄露失败路径。
    func testFailedVaultSwitchKeepsTheCurrentAndPersistedWorkspace() throws {
        let (application, temporaryRoot) = try makeSeededApplication(
            noteNamed: "Stable.md",
            content: "# 稳定 Vault\n"
        )
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        let missing = temporaryRoot.appendingPathComponent(
            "private-missing-vault", isDirectory: true)
        application.launchEnvironment[Self.importVaultEnvironmentKey] = missing.path

        application.launch()
        XCTAssertTrue(noteRow(titled: "稳定 Vault", in: application).waitForExistence(timeout: 10))
        application.descendants(matching: .any)["open-vault"].tap()

        let alert = application.alerts["无法打开 Vault"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts["无法打开此 Vault，请确认它是可访问的文件夹。"].exists)
        XCTAssertFalse(alert.label.contains("private-missing-vault"))
        alert.buttons["好"].tap()
        XCTAssertTrue(noteRow(titled: "稳定 Vault", in: application).waitForExistence(timeout: 10))

        application.terminate()
        application.launchEnvironment.removeValue(forKey: Self.autoOpenVaultEnvironmentKey)
        application.launchEnvironment.removeValue(forKey: Self.importVaultEnvironmentKey)
        application.launch()
        XCTAssertTrue(noteRow(titled: "稳定 Vault", in: application).waitForExistence(timeout: 10))
    }

    /// M-IOS-5.12：损坏书签必须回到选择入口，给出固定说明而不是崩溃或
    /// 暴露本地路径。
    func testInvalidSavedBookmarkFallsBackToTheSelectionPrompt() throws {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }
        let selection =
            [
                "schemaVersion": 1,
                "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "bookmarkData": Data([0, 1, 2, 3]).base64EncodedString(),
            ] as [String: Any]
        try JSONSerialization.data(withJSONObject: selection).write(
            to: temporaryRoot.appendingPathComponent("selected-vault.json")
        )

        application.launch()

        XCTAssertTrue(
            application.descendants(matching: .any)["open-vault-empty-state"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            application.staticTexts[
                "之前选择的 Vault 已失效或无权访问，请重新选择。"
            ].exists
        )
        XCTAssertEqual(
            application.descendants(matching: .any)
                .matching(
                    NSPredicate(
                        format: "label CONTAINS %@",
                        temporaryRoot.lastPathComponent
                    )
                ).count,
            0
        )
    }

    /// 大量标签必须处于真正的滚动容器中；末项可达，并向 VoiceOver 同时表达
    /// 完整层级与命中笔记数。点标签推入的是预置了该过滤条件的卡片流
    /// （REQ-005 FR-003.4），过滤完整身份精确匹配（FR-003.2）且可清除（FR-003.3）。
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

        // FR-003.4：点标签推入预置了该过滤条件的卡片流，而不是旧笔记列表。
        let presetFeed = application.descendants(matching: .any)["card-feed-list"]
        XCTAssertTrue(
            presetFeed.waitForExistence(timeout: 10),
            "Tapping a tag must push the card feed preset with that filter"
        )
        XCTAssertTrue(
            application.descendants(matching: .any)["card-feed-filter-bar"]
                .waitForExistence(timeout: 10),
            "The preset filter must be announced by the filter bar"
        )
        XCTAssertEqual(
            application.descendants(matching: .any)
                .matching(identifier: "workspace-tag-note-list").count,
            0,
            "The old exact-match note list must not reappear"
        )

        // FR-003.2：完整标签身份精确匹配——project/mobile 不含仅标记 project 的笔记。
        let matchingNote = noteRow(titled: "大量标签", in: application)
        XCTAssertTrue(matchingNote.waitForExistence(timeout: 10))
        XCTAssertFalse(
            noteRow(titled: "仅父级标签", in: application).exists,
            "A child tag must not include notes tagged only with its parent"
        )

        presetFeed.swipeDown()
        XCTAssertTrue(presetFeed.waitForExistence(timeout: 10))
        XCTAssertTrue(
            noteRow(titled: "大量标签", in: application).waitForExistence(timeout: 10),
            "The preset filtered feed must remain usable after pull-to-refresh"
        )

        // FR-003.3：预置过滤可清除，清除后回到全部。
        let clear = application.descendants(matching: .any)["card-feed-filter-clear"].firstMatch
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        XCTAssertTrue(
            noteRow(titled: "仅父级标签", in: application).waitForExistence(timeout: 10),
            "Clearing the preset filter must return to the full feed"
        )
    }

    /// AC-REQ-004-02/05 + FR-004：卡片流顶部搜索框复用离线全文搜索，结果以
    /// 卡片呈现；收藏跨重启持久化（紧凑宽度已无「收藏」顶级入口，改由阅读面
    /// 按钮状态断言）；整个流程只能写 App 自己的用户状态，Vault 内所有
    /// Markdown 字节必须保持不变。
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
        let search = application.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), "The card feed must offer search")
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
        XCTAssertTrue(
            noteRow(titled: "可搜索笔记", in: application).waitForExistence(timeout: 10)
        )
        noteRow(titled: "可搜索笔记", in: application).tap()
        let restoredFavorite = application.buttons.matching(
            identifier: "reader-favorite-button"
        ).firstMatch
        XCTAssertTrue(restoredFavorite.waitForExistence(timeout: 10))
        let favoriteRestored = NSPredicate(
            format: "label == %@ AND isEnabled == true",
            "取消收藏"
        )
        expectation(for: favoriteRestored, evaluatedWith: restoredFavorite)
        waitForExpectations(timeout: 10)

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
            application.descendants(matching: .any)["card-feed-list"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(application.tabBars.buttons["标签"].isHittable)
        XCTAssertTrue(application.descendants(matching: .any)["open-vault"].isHittable)
    }

    // MARK: - Seeded-vault helpers

    /// 与 AppDirectories.autoOpenVaultEnvironmentKey 对应（UI 测试目标不链接
    /// 应用模块，故以字面量引用）。
    private static let autoOpenVaultEnvironmentKey = "BEAROBS_AUTOPEN_VAULT"
    private static let importVaultEnvironmentKey = "BEAROBS_UI_TEST_IMPORT_VAULT"

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
        let vault = temporaryRoot.appendingPathComponent("Vault", isDirectory: true)
        try writeNote(named: name, content: content, inVault: vault)
    }

    private func writeNote(named name: String, content: String, inVault vault: URL) throws {
        let note = vault.appendingPathComponent(name)
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
