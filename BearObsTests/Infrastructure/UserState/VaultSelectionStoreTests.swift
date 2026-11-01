import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsUserState
#else
    @testable import BearObs
#endif

final class VaultSelectionStoreTests: XCTestCase {
    func testBookmarkCreationRejectsANonFileURL() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/vault"))

        XCTAssertThrowsError(try VaultSelection.make(for: remoteURL)) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .invalidVaultURL)
        }
    }

    func testStoreInitializationRejectsEveryInvalidDirectoryShape() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/state"))
        XCTAssertThrowsError(try VaultSelectionStore(directory: remoteURL)) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .invalidDirectory)
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try VaultSelectionStore(directory: missing)) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .unavailableDirectory)
        }

        let directory = try makeDirectory()
        let regularFile = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: regularFile)
        XCTAssertThrowsError(try VaultSelectionStore(directory: regularFile)) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .directoryIsNotDirectory)
        }

        let symbolicLink = directory.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: directory
        )
        XCTAssertThrowsError(try VaultSelectionStore(directory: symbolicLink)) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .directoryIsSymbolicLink)
        }
    }

    func testSecurityScopedBookmarkResolvesTheSelectedDirectory() throws {
        let directory = try makeDirectory()
        let selection = try VaultSelection.make(for: directory)

        let resolved = try selection.resolve()

        XCTAssertEqual(
            resolved.url.standardizedFileURL,
            directory.standardizedFileURL
        )
    }

    func testMissingSelectionIsEmpty() throws {
        let directory = try makeDirectory()
        let store = try VaultSelectionStore(directory: directory)

        XCTAssertNil(try store.load())
    }

    func testSelectionRoundTripsWithoutExposingThePath() throws {
        let directory = try makeDirectory()
        let store = try VaultSelectionStore(directory: directory)
        let selection = VaultSelection(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            bookmarkData: Data([0, 1, 2, 255])
        )

        try store.save(selection)

        XCTAssertEqual(try store.load(), selection)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("selected-vault.json").path
            )
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("selected-vault.json").path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testEveryPrecommitFailurePreservesThePreviouslySelectedVault() throws {
        for failingCheckpoint in [
            VaultSelectionSaveCheckpoint.beforePermissions,
            .beforeFileSync,
            .beforeRename,
        ] {
            let directory = try makeDirectory()
            let store = try VaultSelectionStore(directory: directory)
            let first = VaultSelection(
                id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
                bookmarkData: Data([1, 2, 3])
            )
            let second = VaultSelection(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                bookmarkData: Data([4, 5, 6])
            )
            try store.save(first)
            let failingStore = try VaultSelectionStore(directory: directory) { checkpoint in
                if checkpoint == failingCheckpoint {
                    throw InjectedSaveFailure()
                }
            }

            XCTAssertThrowsError(try failingStore.save(second)) {
                XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionWriteFailed)
            }
            XCTAssertEqual(try store.load(), first)
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: directory.path),
                ["selected-vault.json"]
            )
        }
    }

    func testRejectsASelectionFileSymlink() throws {
        let directory = try makeDirectory()
        let target = directory.appendingPathComponent("outside.json")
        let selectionFile = directory.appendingPathComponent("selected-vault.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: selectionFile,
            withDestinationURL: target
        )
        let store = try VaultSelectionStore(directory: directory)

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionFileIsSymbolicLink)
        }
    }

    func testLoadRejectsMalformedUnsupportedAndEmptySelections() throws {
        let directory = try makeDirectory()
        let selectionFile = directory.appendingPathComponent("selected-vault.json")
        let store = try VaultSelectionStore(directory: directory)

        try Data("{".utf8).write(to: selectionFile)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .invalidSelection)
        }

        try persistedSelectionJSON(schemaVersion: 2, bookmarkData: Data([1]))
            .write(to: selectionFile)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .unsupportedSchemaVersion)
        }

        try persistedSelectionJSON(schemaVersion: 1, bookmarkData: Data())
            .write(to: selectionFile)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .invalidSelection)
        }
    }

    func testLoadRejectsNonRegularAndOversizedSelectionFiles() throws {
        let directory = try makeDirectory()
        let selectionFile = directory.appendingPathComponent("selected-vault.json")
        let store = try VaultSelectionStore(directory: directory)

        try FileManager.default.createDirectory(
            at: selectionFile, withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionFileIsNotRegular)
        }

        try FileManager.default.removeItem(at: selectionFile)
        try Data(repeating: 0, count: 1_048_577).write(to: selectionFile)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionFileTooLarge)
        }
    }

    func testSaveRejectsEmptyBookmarkAndExistingDestinationSymlink() throws {
        let directory = try makeDirectory()
        let store = try VaultSelectionStore(directory: directory)

        XCTAssertThrowsError(try store.save(VaultSelection(bookmarkData: Data()))) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .invalidSelection)
        }

        let target = directory.appendingPathComponent("outside.json")
        let selectionFile = directory.appendingPathComponent("selected-vault.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: selectionFile,
            withDestinationURL: target
        )
        XCTAssertThrowsError(
            try store.save(VaultSelection(bookmarkData: Data([1])))
        ) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionFileIsSymbolicLink)
        }
    }

    func testSaveRejectsANonReplaceableDestinationDirectory() throws {
        let directory = try makeDirectory()
        let selectionFile = directory.appendingPathComponent("selected-vault.json")
        try FileManager.default.createDirectory(
            at: selectionFile,
            withIntermediateDirectories: false
        )
        let store = try VaultSelectionStore(directory: directory)

        XCTAssertThrowsError(
            try store.save(VaultSelection(bookmarkData: Data([1])))
        ) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionWriteFailed)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["selected-vault.json"]
        )
    }

    func testReplacingTheStoreDirectoryFailsClosedForLoadAndSave() throws {
        let directory = try makeDirectory()
        let displacedDirectory =
            directory
            .deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: displacedDirectory) }
        let store = try VaultSelectionStore(directory: directory)

        try FileManager.default.moveItem(at: directory, to: displacedDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionReadFailed)
        }
        XCTAssertThrowsError(
            try store.save(VaultSelection(bookmarkData: Data([1])))
        ) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionWriteFailed)
        }
    }
}

private struct InjectedSaveFailure: Error {}

extension VaultSelectionStoreTests {
    fileprivate func persistedSelectionJSON(
        schemaVersion: Int,
        bookmarkData: Data
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": schemaVersion,
                "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "bookmarkData": bookmarkData.base64EncodedString(),
            ]
        )
    }

    fileprivate func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
