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
        XCTAssertEqual(
            AppWorkspaceModel.vaultRecoveryMessage(for: AppEnvironmentError.unavailable),
            "无法准备本地数据，请稍后重试。"
        )
        XCTAssertEqual(
            AppWorkspaceModel.vaultRecoveryMessage(for: PrivateImportFailure.sensitivePath),
            "之前选择的 Vault 已失效或无权访问，请重新选择。"
        )
    }

    func testVaultImportDecisionHandlesEmptySelectionAndBothCancellationShapes() {
        let selected = URL(fileURLWithPath: "/selected-vault", isDirectory: true)

        XCTAssertEqual(
            AppWorkspaceModel.vaultImportDecision(for: .success([selected])),
            .selected(selected)
        )
        XCTAssertEqual(
            AppWorkspaceModel.vaultImportDecision(for: .success([])),
            .failed
        )
        XCTAssertEqual(
            AppWorkspaceModel.vaultImportDecision(for: .failure(CancellationError())),
            .cancelled
        )
    }

    func testOpenVaultWithoutPreparedStoresFailsWithFixedMessage() {
        let model = AppWorkspaceModel(environment: .unavailable)

        model.openVault(URL(fileURLWithPath: "/new-vault", isDirectory: true))

        XCTAssertNil(model.vaultURL)
        XCTAssertEqual(model.errorMessage, "无法准备本地数据目录。")
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

    func testSwitchingVaultsRebuildsTheIndexAndKeepsFavoritesIsolated() async throws {
        let fixture = try makeVaultFixture()
        let path = try VaultPath(decodedRelativePath: "Shared.md")
        let model = AppWorkspaceModel(
            environment: .unavailable,
            directories: fixture.directories,
            selectionStore: fixture.selectionStore
        )

        model.openVault(fixture.vaultA)
        let firstID = try XCTUnwrap(model.environment.vaultID)
        await model.environment.libraryModel.load()
        await model.environment.favoritesModel.load()
        await model.environment.favoritesModel.setFavorite(path, isFavorite: true)
        XCTAssertEqual(
            model.environment.libraryModel.state.visibleNotes.map(\.title),
            ["Vault A"]
        )
        XCTAssertEqual(model.environment.favoritesModel.favoritePaths, [path])

        model.openVault(fixture.vaultB)
        let secondID = try XCTUnwrap(model.environment.vaultID)
        await model.environment.libraryModel.load()
        await model.environment.favoritesModel.load()

        XCTAssertNotEqual(secondID, firstID)
        XCTAssertEqual(model.vaultURL, fixture.vaultB)
        XCTAssertEqual(
            model.environment.libraryModel.state.visibleNotes.map(\.title),
            ["Vault B"]
        )
        XCTAssertTrue(model.environment.favoritesModel.favoritePaths.isEmpty)
        XCTAssertEqual(try fixture.selectionStore.load()?.id, secondID)
        let firstUserState = try FileUserStateStore(
            metadataDirectory: fixture.directories.metadata(for: firstID)
        )
        let firstFavoritePaths = try await firstUserState.favoritePaths()
        XCTAssertEqual(firstFavoritePaths, [path])
    }

    func testFailedVaultSwitchKeepsTheCurrentEnvironmentAndPersistedSelection() throws {
        let fixture = try makeVaultFixture()
        let model = AppWorkspaceModel(
            environment: .unavailable,
            directories: fixture.directories,
            selectionStore: fixture.selectionStore
        )
        model.openVault(fixture.vaultA)
        let firstID = try XCTUnwrap(model.environment.vaultID)
        let invalidVault = fixture.root.appendingPathComponent("Not-A-Vault.md")
        try Data("not a directory".utf8).write(to: invalidVault)

        model.openVault(invalidVault)

        XCTAssertEqual(model.environment.vaultID, firstID)
        XCTAssertEqual(model.vaultURL, fixture.vaultA)
        XCTAssertEqual(try fixture.selectionStore.load()?.id, firstID)
        XCTAssertEqual(
            model.errorMessage,
            "无法打开此 Vault，请确认它是可访问的文件夹。"
        )
        XCTAssertFalse(model.errorMessage?.contains(invalidVault.path) == true)
        XCTAssertEqual(try vaultDataIDs(in: fixture.directories), [firstID])
    }

    func testSelectionSaveFailureRemovesPreparedMetadataAndKeepsTheCurrentVault() throws {
        let fixture = try makeVaultFixture()
        let initialModel = AppWorkspaceModel(
            environment: .unavailable,
            directories: fixture.directories,
            selectionStore: fixture.selectionStore
        )
        initialModel.openVault(fixture.vaultA)
        let firstID = try XCTUnwrap(initialModel.environment.vaultID)
        let failingStore = try VaultSelectionStore(directory: fixture.directories.root) {
            checkpoint in
            if checkpoint == .beforeRename {
                throw PrivateSaveFailure.injected
            }
        }
        let model = AppWorkspaceModel(
            environment: initialModel.environment,
            vaultURL: fixture.vaultA,
            directories: fixture.directories,
            selectionStore: failingStore
        )

        model.openVault(fixture.vaultB)

        XCTAssertEqual(model.environment.vaultID, firstID)
        XCTAssertEqual(model.vaultURL, fixture.vaultA)
        XCTAssertEqual(try fixture.selectionStore.load()?.id, firstID)
        XCTAssertEqual(try vaultDataIDs(in: fixture.directories), [firstID])
        XCTAssertEqual(
            model.errorMessage,
            "无法打开此 Vault，请确认它是可访问的文件夹。"
        )
    }

    private func makeVaultFixture() throws -> (
        root: URL,
        vaultA: URL,
        vaultB: URL,
        directories: AppDirectories,
        selectionStore: VaultSelectionStore
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BearObsVaultSwitch-\(UUID().uuidString)",
            isDirectory: true
        )
        let directories = try AppDirectories.makeLive(
            environment: [AppDirectories.appSupportOverrideEnvironmentKey: root.path]
        )
        let vaultA = root.appendingPathComponent("Vault-A", isDirectory: true)
        let vaultB = root.appendingPathComponent("Vault-B", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vaultB, withIntermediateDirectories: true)
        try Data("# Vault A\n".utf8).write(
            to: vaultA.appendingPathComponent("Shared.md")
        )
        try Data("# Vault B\n".utf8).write(
            to: vaultB.appendingPathComponent("Shared.md")
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (
            root,
            vaultA,
            vaultB,
            directories,
            try VaultSelectionStore(directory: directories.root)
        )
    }

    private func vaultDataIDs(in directories: AppDirectories) throws -> [UUID] {
        try FileManager.default.contentsOfDirectory(
            at: directories.vaults,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .compactMap { UUID(uuidString: $0.lastPathComponent) }
        .sorted { $0.uuidString < $1.uuidString }
    }

    private enum PrivateImportFailure: Error {
        case sensitivePath
    }

    private enum PrivateSaveFailure: Error {
        case injected
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

    func testFailedInitialScanClearsTheInFlightTask() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let vault = directory.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
        let scanner = try IncrementalIndexScanner(root: vault, repository: repository)
        let readiness = IndexReadiness(scanner: scanner)
        try FileManager.default.removeItem(at: vault)

        do {
            try await readiness.ensureReady()
            XCTFail("Expected the missing Vault to fail the initial scan")
        } catch {
            let requiresInitialIndex = await readiness.requiresInitialIndex()
            let latestReport = await readiness.latestReport()
            XCTAssertTrue(requiresInitialIndex)
            XCTAssertNil(latestReport)
        }
    }
}
