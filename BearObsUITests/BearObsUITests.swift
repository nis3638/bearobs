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

    // MARK: - REQ-002 P6: keyboard, VoiceOver surface and failure paths
    //
    // 每条测试用例自建临时 Vault 与笔记，经 BEAROBS_AUTOPEN_VAULT 在启动时
    // 直接打开，不读取也不写入开发者机器上的真实 Vault。
    //
    // 快捷键投递的实测结论（macOS 27 + Xcode 26.5）：
    // - 编辑表面为第一响应者时，typeKey 能把 Command 组合键与 Escape 送进
    //   AppKit 表面的真实处理路径（performKeyEquivalent / cancelOperation），
    //   Command-S、Command-L、Escape 因此按真实路径验证；
    // - 合成键盘事件到不了菜单键等价阶段，Command-E 的菜单命令无法用按键
    //   触发，因此以“菜单命令存在、启用并触发编辑”验证键盘入口，⌘E 绑定
    //   本身留待人工走查确认（见 REQ-002 VoiceOver checklist）。

    /// Command-E 的键盘入口（菜单命令）打开当前阅读面的编辑态。
    private func enterEditingThroughKeyboardEntry(in application: XCUIApplication) {
        let editor = editorSurface(in: application)
        let fileMenu = application.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5), "The File menu must exist")
        fileMenu.click()
        let editCommand = fileMenu.menus.menuItems["编辑笔记"]
        XCTAssertTrue(
            editCommand.waitForExistence(timeout: 5),
            "The 编辑笔记 keyboard entry must exist"
        )
        // 菜单校验是惰性的，启用状态可能晚一拍，轮询等待；全量并行时
        // focusedSceneValue 传播可能明显滞后，给足与其它等待一致的 10 s。
        // 实测 isHittable 对菜单项不可靠（可点击但持续报告 false），不能作为
        // 点击前门；菜单窗口布局期偶发的 INFINITY 命中点属 XCUITest 事件
        // 合成层问题，测试侧无法先行探测。
        waitUntil(timeout: 10) { editCommand.isEnabled }
        editCommand.click()
        XCTAssertTrue(
            editor.waitForExistence(timeout: 10),
            "The keyboard entry must open the editor"
        )
    }

    /// AC-REQ-002-06：键盘入口进入编辑，Command-S 保存，内容落盘。
    func testKeyboardEntersEditingAndCommandSSavesTheDraft() throws {
        let (application, temporaryRoot, note) = try makeSeededApplication(
            noteNamed: "P6EditNote.md", content: "# 键盘验收\n\n第一段。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()
        openNote(titled: "键盘验收", in: application)
        enterEditingThroughKeyboardEntry(in: application)

        let editor = editorSurface(in: application)
        editor.click()
        editor.typeText("键盘新内容")

        application.typeKey("s", modifierFlags: .command)
        let saved = try waitForFile(note, containing: "键盘新内容")
        XCTAssertTrue(saved.contains("# 键盘验收"), "Saved note must keep the rest of the file")

        waitUntil { application.buttons["inline-editor-save-button"].isEnabled == false }
    }

    /// AC-REQ-002-06：Escape 经过 dirty guard，可继续编辑也可放弃修改。
    func testEscapeGoesThroughTheDirtyGuard() throws {
        let (application, temporaryRoot, note) = try makeSeededApplication(
            noteNamed: "P6EscapeNote.md", content: "# 离开保护\n\n原始段落。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()
        openNote(titled: "离开保护", in: application)
        enterEditingThroughKeyboardEntry(in: application)

        let editor = editorSurface(in: application)
        editor.click()
        editor.typeText("未保存文字")

        application.typeKey(.escape, modifierFlags: [])
        let continueButton = sheetButton("继续编辑", in: application)
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "A dirty draft must raise the discard confirmation on Escape"
        )
        continueButton.click()

        XCTAssertTrue(
            editorSurface(in: application).exists,
            "Continuing must stay in the editor"
        )
        XCTAssertTrue(editorValue(in: application).contains("未保存文字"))

        application.typeKey(.escape, modifierFlags: [])
        let discardButton = sheetButton("放弃修改", in: application)
        XCTAssertTrue(discardButton.waitForExistence(timeout: 10))
        discardButton.click()

        XCTAssertTrue(
            application.descendants(matching: .any)["reader-content"]
                .waitForExistence(timeout: 10),
            "Discarding must return to the reader"
        )
        let onDisk = try String(contentsOf: note, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("未保存文字"), "Discarding must not write the draft")
    }

    /// REQ-002 P6：任务 marker 的键盘切换路径（Command-L，光标所在任务行）。
    func testCommandLTogglesTheTaskMarkerOnTheCaretLine() throws {
        let (application, temporaryRoot, note) = try makeSeededApplication(
            noteNamed: "P6TaskNote.md", content: "- [ ] 任务一项\n\n正文段落。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()
        // 该笔记没有 H1，列表标题回落为文件名。
        openNote(titled: "P6TaskNote", in: application)
        enterEditingThroughKeyboardEntry(in: application)

        // 进入编辑态后插入点落在首个可见可编辑位置（任务行首），无需点击。
        application.typeKey("l", modifierFlags: .command)

        application.typeKey("s", modifierFlags: .command)
        let saved = try waitForFile(note, containing: "- [x] 任务一项")
        XCTAssertTrue(saved.contains("正文段落。"))
    }

    /// AC-REQ-002-04：保存失败不关闭编辑态、草稿不丢；重试走同一保存路径。
    func testSaveFailureKeepsTheEditorAndRetryPreservesTheDraft() throws {
        let (application, temporaryRoot, note) = try makeSeededApplication(
            noteNamed: "P6FailureNote.md", content: "# 失败验收\n\n原始段落。\n")
        let vault = note.deletingLastPathComponent()
        // 无论断言走到哪一步，都要恢复目录权限，保证临时 Vault 可被清理。
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: vault.path)
        }
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launch()
        openNote(titled: "失败验收", in: application)
        enterEditingThroughKeyboardEntry(in: application)

        let editor = editorSurface(in: application)
        editor.click()
        editor.typeText("失败时仍在的草稿")

        // 让保存必败：Vault 目录只读，原子替换无法落盘。
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o555))], ofItemAtPath: vault.path)
        application.typeKey("s", modifierFlags: .command)

        // 失败条的标识符会被容器标识继承覆盖，按用户可见的标题与按钮查询。
        let failureTitle = application.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "无法保存笔记", "无法保存笔记"
                )
            )
            .firstMatch
        XCTAssertTrue(
            failureTitle.waitForExistence(timeout: 10),
            "The failure must surface inside the detail column"
        )
        let retryButton = application.buttons["重试保存"]
        XCTAssertTrue(
            retryButton.waitForExistence(timeout: 5),
            "A plain save failure must offer a retry"
        )
        XCTAssertTrue(
            editorSurface(in: application).exists,
            "A failed save must not close the editor"
        )
        // 焦点仍在编辑器：失败条不抢占键盘焦点，草稿可继续输入。
        editor.typeText("追加")

        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))], ofItemAtPath: vault.path)
        retryButton.click()

        waitUntil {
            !failureTitle.exists && !retryButton.exists
        }
        let saved = try waitForFile(note, containing: "失败时仍在的草稿追加")
        XCTAssertTrue(saved.contains("# 失败验收"))
    }

    /// AC-REQ-002-06：深色模式 + 最大辅助字号下编辑表面仍可操作。
    func testEditorOperatesInDarkModeAtLargestAccessibilitySize() throws {
        let (application, temporaryRoot, _) = try makeSeededApplication(
            noteNamed: "P6DarkNote.md", content: "# 深色验收\n\n暗色段落。\n")
        defer { cleanUp(application: application, temporaryRoot: temporaryRoot) }

        application.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            "-AppleInterfaceStyle",
            "Dark",
        ]
        application.launch()
        openNote(titled: "深色验收", in: application)
        enterEditingThroughKeyboardEntry(in: application)

        let editor = editorSurface(in: application)
        editor.click()
        editor.typeText("大字号")

        application.typeKey(.escape, modifierFlags: [])
        let continueButton = sheetButton("继续编辑", in: application)
        XCTAssertTrue(
            continueButton.waitForExistence(timeout: 10),
            "The dirty guard must stay operable at the largest accessibility size"
        )
        sheetButton("放弃修改", in: application).click()
        XCTAssertTrue(
            application.descendants(matching: .any)["reader-content"].waitForExistence(timeout: 10)
        )
    }

    private func sheetButton(
        _ label: String, in application: XCUIApplication
    ) -> XCUIElement {
        // 详情栏与外壳各有一个同文案的放弃确认对话框，隐藏的那个不在
        // sheet 层级里，用 sheet 限定到当前展示的对话框。
        application.sheets.buttons[label].firstMatch
    }

    // MARK: - Seeded-vault helpers

    /// UI 测试自建 Vault 的启动直开开关，与 AppDirectories.autoOpenVaultEnvironmentKey
    /// 对应（UI 测试目标不链接应用模块，故以字面量引用）。
    private static let autoOpenVaultEnvironmentKey = "BEAROBS_AUTOPEN_VAULT"

    private func makeSeededApplication(
        noteNamed name: String, content: String
    ) throws -> (application: XCUIApplication, temporaryRoot: URL, note: URL) {
        let (application, temporaryRoot) = try makeIsolatedApplication()
        let vault = temporaryRoot.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vault, withIntermediateDirectories: true)
        let note = vault.appendingPathComponent(name)
        try content.write(to: note, atomically: true, encoding: .utf8)
        application.launchEnvironment[Self.autoOpenVaultEnvironmentKey] = vault.path
        return (application, temporaryRoot, note)
    }

    private func openNote(titled title: String, in application: XCUIApplication) {
        let list = application.descendants(matching: .any)["workspace-note-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), "The note list must be visible")
        // 笔记行是合并的可访问元素，标题文本落在 value（H1 或文件名派生），
        // 不一定在 label，因此两个字段都匹配。
        let row = application.descendants(matching: .any)
            .matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)
            )
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Expected a row for \(title)")
        row.click()
        XCTAssertTrue(
            application.descendants(matching: .any)["reader-edit-button"]
                .waitForExistence(timeout: 10),
            "The reader must present the edit button"
        )
    }

    private func editorSurface(in application: XCUIApplication) -> XCUIElement {
        application.descendants(matching: .any)["inline-editor-text"].firstMatch
    }

    private func editorValue(in application: XCUIApplication) -> String {
        let editor = editorSurface(in: application)
        if let value = editor.value as? String { return value }
        return editor.label
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for a UI condition.", file: file, line: line)
                return
            }
            usleep(100_000)
        }
    }

    private func waitForFile(
        _ url: URL, containing needle: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while Date() < deadline {
            last = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if last.contains(needle) { return last }
            usleep(200_000)
        }
        XCTFail(
            "File \(url.lastPathComponent) did not contain \(needle) in time; last: \(last)",
            file: file,
            line: line
        )
        return last
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
