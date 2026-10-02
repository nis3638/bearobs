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

    func testWorkspaceDestinationRoundTripsStableRestorationIdentifiers() {
        let destinations: [WorkspaceDestination] = [
            .section(.notes),
            .section(.favorites),
            .tag("project/mobile"),
        ]

        for destination in destinations {
            XCTAssertEqual(
                WorkspaceDestination.restore(from: destination.restorationID),
                destination
            )
        }
    }

    func testWorkspaceDestinationFallsBackForInvalidRestorationIdentifiers() {
        XCTAssertEqual(WorkspaceDestination.restore(from: nil), .section(.notes))
        XCTAssertEqual(WorkspaceDestination.restore(from: "section:removed"), .section(.notes))
        XCTAssertEqual(WorkspaceDestination.restore(from: "tag:"), .section(.notes))
        XCTAssertEqual(WorkspaceDestination.restore(from: "garbage"), .section(.notes))
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

@MainActor
final class AppWorkspaceModelTests: XCTestCase {
    func testVaultRecoveryDistinguishesNoSelectionFromInvalidBookmark() {
        XCTAssertNil(
            AppWorkspaceModel.vaultRecoveryMessage(
                for: AppEnvironmentError.vaultNotSelected
            )
        )
        XCTAssertEqual(
            AppWorkspaceModel.vaultRecoveryMessage(
                for: AppEnvironmentError.invalidSelectedVault
            ),
            "之前选择的 Vault 已失效或无权访问，请重新选择。"
        )
        XCTAssertEqual(
            AppWorkspaceModel.vaultRecoveryMessage(
                for: AppEnvironmentError.applicationSupportUnavailable
            ),
            "无法准备本地数据，请稍后重试。"
        )
        XCTAssertEqual(
            AppWorkspaceModel.vaultRecoveryMessage(
                for: VaultSelectionStoreError.invalidSelection
            ),
            "无法恢复之前选择的 Vault，请重新选择。"
        )
    }

    func testImporterCancellationPreservesTheCurrentWorkspaceState() {
        let vault = URL(fileURLWithPath: "/stable-vault", isDirectory: true)
        let model = AppWorkspaceModel(
            environment: .unavailable,
            vaultURL: vault,
            errorMessage: "保留现状"
        )
        let cancellation = NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError
        )

        model.handleVaultImport(.failure(cancellation))

        XCTAssertEqual(model.vaultURL, vault)
        XCTAssertEqual(model.errorMessage, "保留现状")
    }

    func testImporterFailureKeepsTheCurrentVaultAndShowsFixedMessage() {
        let vault = URL(fileURLWithPath: "/stable-vault", isDirectory: true)
        let model = AppWorkspaceModel(
            environment: .unavailable,
            vaultURL: vault
        )

        model.handleVaultImport(.failure(PrivateImportFailure.sensitivePath))

        XCTAssertEqual(model.vaultURL, vault)
        XCTAssertEqual(model.errorMessage, "无法完成文件夹选择，请稍后重试。")
    }

    func testOpeningTheCurrentVaultPreservesItsExistingIdentity() {
        let vault = URL(fileURLWithPath: "/stable-vault", isDirectory: true)
        let model = AppWorkspaceModel(
            environment: .unavailable,
            vaultURL: vault,
            errorMessage: "old error"
        )

        model.openVault(vault)

        XCTAssertEqual(model.vaultURL, vault)
        XCTAssertNil(model.errorMessage)
    }

    private enum PrivateImportFailure: Error {
        case sensitivePath
    }
}

final class IndexReadinessTests: XCTestCase {
    func testRetainsTheLatestIncrementalScanReport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vault = directory.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# Indexed".utf8).write(
            to: vault.appendingPathComponent("note.md")
        )
        let repository = try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
        let scanner = try IncrementalIndexScanner(root: vault, repository: repository)
        let readiness = IndexReadiness(scanner: scanner)

        let initial = await readiness.latestReport()
        XCTAssertNil(initial)
        try await readiness.ensureReady()
        let first = await readiness.latestReport()
        XCTAssertEqual(first, .init(indexed: 1))

        try await readiness.refresh()
        let second = await readiness.latestReport()
        XCTAssertEqual(second, .init(metadataSkipped: 1))
    }
}
