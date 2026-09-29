import XCTest

@testable import BearObs

final class WorkspaceSectionTests: XCTestCase {
    func testDesktopWorkspaceNavigationKeepsCoreCollectionsInTheSidebar() {
        XCTAssertEqual(
            WorkspaceSection.allCases.map(\.title),
            ["笔记", "最近", "收藏", "搜索"]
        )
    }

    func testTagDestinationRetainsTheCompleteNormalizedIdentity() {
        let destination = WorkspaceDestination.tag("project/mobile")

        XCTAssertEqual(destination.tagIdentity, "project/mobile")
    }

    func testSelectionPolicyKeepsOnlyAPathStillPresentInTheNewList() throws {
        let selected = try VaultPath(decodedRelativePath: "selected.md")
        let other = try VaultPath(decodedRelativePath: "other.md")

        XCTAssertEqual(
            WorkspaceSelectionPolicy.retainedPath(
                selected,
                in: [selected, other]
            ),
            selected
        )
        XCTAssertNil(WorkspaceSelectionPolicy.retainedPath(selected, in: [other]))
        XCTAssertNil(WorkspaceSelectionPolicy.retainedPath(nil, in: [selected]))
    }

    func testSelectionPolicyRequiresDiscardConfirmationBeforeReplacingDirtyNote() throws {
        let current = try VaultPath(decodedRelativePath: "current.md")
        let next = try VaultPath(decodedRelativePath: "next.md")

        XCTAssertEqual(
            WorkspaceSelectionPolicy.transition(
                from: current,
                to: next,
                hasUnsavedChanges: true
            ),
            .requiresDiscardConfirmation(next)
        )
        XCTAssertEqual(
            WorkspaceSelectionPolicy.transition(
                from: current,
                to: next,
                hasUnsavedChanges: false
            ),
            .select(next)
        )
    }

    func testSelectionPolicyFallsBackWhenTheRequestedTagDisappears() {
        let requested = makeTag("project")

        XCTAssertEqual(
            WorkspaceSelectionPolicy.reconciledDestination(
                .tag(requested.normalizedName),
                availableTags: [],
                selectedTag: requested,
                selectedNotesState: .content([])
            ),
            .section(.notes)
        )
    }

    func testSelectionPolicyRestoresTheStableTagAfterASelectionCancellation() {
        let previous = makeTag("project")
        let requested = makeTag("project/mobile")

        XCTAssertEqual(
            WorkspaceSelectionPolicy.reconciledDestination(
                .tag(requested.normalizedName),
                availableTags: [previous, requested],
                selectedTag: previous,
                selectedNotesState: .content([])
            ),
            .tag(previous.normalizedName)
        )
    }

    func testSelectionPolicyFallsBackToNotesAfterInitialSelectionCancellation() {
        let requested = makeTag("project")

        XCTAssertEqual(
            WorkspaceSelectionPolicy.reconciledDestination(
                .tag(requested.normalizedName),
                availableTags: [requested],
                selectedTag: nil,
                selectedNotesState: .empty
            ),
            .section(.notes)
        )
    }

    func testSelectionPolicyKeepsTheRequestedTagWhileItsNotesAreLoading() {
        let previous = makeTag("project")
        let requested = makeTag("project/mobile")

        XCTAssertEqual(
            WorkspaceSelectionPolicy.reconciledDestination(
                .tag(requested.normalizedName),
                availableTags: [previous, requested],
                selectedTag: previous,
                selectedNotesState: .loading
            ),
            .tag(requested.normalizedName)
        )
    }

    func testDesktopWorkspaceExplainsWhatTheEmptyDetailColumnNeeds() {
        XCTAssertEqual(WorkspaceLayout.emptyDetailTitle, "选择一篇笔记")
        XCTAssertEqual(
            WorkspaceLayout.emptyDetailMessage,
            "从中间列表选择笔记后，会在这里打开阅读。"
        )
    }

    private func makeTag(_ normalizedName: String) -> IndexedTagSummary {
        IndexedTagSummary(
            normalizedName: normalizedName,
            displayName: normalizedName,
            noteCount: 1
        )
    }
}

final class AppDirectoriesTests: XCTestCase {
    func testMakeLiveHonorsTheApplicationSupportOverride() throws {
        let temporaryRoot = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "BearObsAppDirectories-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let directories = try AppDirectories.makeLive(
            environment: [AppDirectories.appSupportOverrideEnvironmentKey: temporaryRoot.path]
        )

        XCTAssertEqual(directories.root, temporaryRoot)
        XCTAssertEqual(
            directories.vaults,
            temporaryRoot.appendingPathComponent("Vaults", isDirectory: true)
        )
        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directories.vaults.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testMakeLiveTreatsAnEmptyOverrideAsUnset() throws {
        let directories = try AppDirectories.makeLive(
            environment: [AppDirectories.appSupportOverrideEnvironmentKey: ""]
        )

        XCTAssertTrue(directories.root.path.hasSuffix("BearObs"))
        XCTAssertTrue(directories.root.path.contains("Application Support"))
    }
}
