import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsUserState
#else
    @testable import BearObs
#endif

final class FileUserStateStoreTests: XCTestCase {
    func testMissingStateReturnsEmptyWithoutCreatingAFile() async throws {
        let metadata = try makeDirectory()
        let state = stateFile(in: metadata)
        let store = try FileUserStateStore(metadataDirectory: metadata)

        let favorites = try await store.favoritePaths()

        XCTAssertEqual(favorites, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.path))
    }

    func testFavoritePersistsWhenTheStoreIsRecreated() async throws {
        let metadata = try makeDirectory()
        let path = try makePath("Projects/Plan.md")
        let firstStore = try FileUserStateStore(metadataDirectory: metadata)

        let written = try await firstStore.setFavorite(path, isFavorite: true)
        let secondStore = try FileUserStateStore(metadataDirectory: metadata)
        let reloaded = try await secondStore.favoritePaths()

        XCTAssertEqual(written, [path])
        XCTAssertEqual(reloaded, [path])
    }

    func testCancellingAFavoriteRemovesOnlyThatPathAndPersists() async throws {
        let metadata = try makeDirectory()
        let removed = try makePath("Projects/Removed.md")
        let retained = try makePath("Projects/Retained.md")
        let store = try FileUserStateStore(metadataDirectory: metadata)
        _ = try await store.setFavorite(removed, isFavorite: true)
        _ = try await store.setFavorite(retained, isFavorite: true)

        let updated = try await store.setFavorite(removed, isFavorite: false)
        let reloadedStore = try FileUserStateStore(metadataDirectory: metadata)
        let reloaded = try await reloadedStore.favoritePaths()

        XCTAssertEqual(updated, [retained])
        XCTAssertEqual(reloaded, [retained])
    }

    func testRepeatedFavoriteAndCancellationAreIdempotent() async throws {
        let metadata = try makeDirectory()
        let path = try makePath("Pinned.md")
        let state = stateFile(in: metadata)
        let store = try FileUserStateStore(metadataDirectory: metadata)

        _ = try await store.setFavorite(path, isFavorite: true)
        let firstFavoriteBytes = try Data(contentsOf: state)
        let repeatedFavorite = try await store.setFavorite(path, isFavorite: true)
        let secondFavoriteBytes = try Data(contentsOf: state)

        _ = try await store.setFavorite(path, isFavorite: false)
        let firstCancellationBytes = try Data(contentsOf: state)
        let repeatedCancellation = try await store.setFavorite(path, isFavorite: false)
        let secondCancellationBytes = try Data(contentsOf: state)

        XCTAssertEqual(repeatedFavorite, [path])
        XCTAssertEqual(firstFavoriteBytes, secondFavoriteBytes)
        XCTAssertEqual(repeatedCancellation, [])
        XCTAssertEqual(firstCancellationBytes, secondCancellationBytes)
    }

    func testConcurrentFavoritesDoNotLoseUpdates() async throws {
        let metadata = try makeDirectory()
        let store = try FileUserStateStore(metadataDirectory: metadata)
        let paths = try (0..<64).map {
            try makePath("Concurrent/Note-\($0).md")
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for path in paths {
                group.addTask {
                    _ = try await store.setFavorite(path, isFavorite: true)
                }
            }
            try await group.waitForAll()
        }

        let inMemory = try await store.favoritePaths()
        let reloadedStore = try FileUserStateStore(metadataDirectory: metadata)
        let persisted = try await reloadedStore.favoritePaths()

        XCTAssertEqual(inMemory, Set(paths))
        XCTAssertEqual(persisted, Set(paths))
    }

    func testJSONBytesAreCompactAndDeterministicAcrossInsertionOrders() async throws {
        let firstMetadata = try makeDirectory()
        let secondMetadata = try makeDirectory()
        let paths = try [
            makePath("folder/zulu.md"),
            makePath("alpha.md"),
            makePath("folder/middle.md"),
        ]
        let firstStore = try FileUserStateStore(metadataDirectory: firstMetadata)
        let secondStore = try FileUserStateStore(metadataDirectory: secondMetadata)

        for path in paths {
            _ = try await firstStore.setFavorite(path, isFavorite: true)
        }
        for path in paths.reversed() {
            _ = try await secondStore.setFavorite(path, isFavorite: true)
        }

        let firstBytes = try Data(contentsOf: stateFile(in: firstMetadata))
        let secondBytes = try Data(contentsOf: stateFile(in: secondMetadata))
        let expected = Data(
            #"{"favorites":["alpha.md","folder/middle.md","folder/zulu.md"],"schemaVersion":1}"#
                .utf8
        )

        XCTAssertEqual(firstBytes, secondBytes)
        XCTAssertEqual(firstBytes, expected)
    }

    func testInvalidVaultPathInJSONFailsClosed() async throws {
        let metadata = try makeDirectory()
        try write(
            Data(#"{"favorites":["safe.md","../escape.md"],"schemaVersion":1}"#.utf8),
            to: stateFile(in: metadata)
        )
        let store = try FileUserStateStore(metadataDirectory: metadata)

        await assertThrows(.invalidState) {
            _ = try await store.favoritePaths()
        }
    }

    func testCorruptJSONFailsClosedAndAMutationDoesNotReplaceIt() async throws {
        let metadata = try makeDirectory()
        let state = stateFile(in: metadata)
        let original = Data(#"{"favorites":["stable.md"],"schemaVersion":1"#.utf8)
        try write(original, to: state)
        let store = try FileUserStateStore(metadataDirectory: metadata)
        let attempted = try makePath("Attempted.md")

        await assertThrows(.invalidState) {
            _ = try await store.favoritePaths()
        }
        await assertThrows(.invalidState) {
            _ = try await store.setFavorite(attempted, isFavorite: true)
        }

        XCTAssertEqual(try Data(contentsOf: state), original)
    }

    func testUnknownSchemaFailsClosedWithoutBeingDowngraded() async throws {
        let metadata = try makeDirectory()
        let state = stateFile(in: metadata)
        let original = Data(
            #"{"favorites":["stable.md"],"schemaVersion":2}"#.utf8
        )
        try write(original, to: state)
        let store = try FileUserStateStore(metadataDirectory: metadata)
        let attempted = try makePath("Attempted.md")

        await assertThrows(.unsupportedSchemaVersion) {
            _ = try await store.favoritePaths()
        }
        await assertThrows(.unsupportedSchemaVersion) {
            _ = try await store.setFavorite(attempted, isFavorite: true)
        }

        XCTAssertEqual(try Data(contentsOf: state), original)
    }

    func testStateLargerThanOneMiBFailsBeforeJSONDecoding() async throws {
        let metadata = try makeDirectory()
        let state = stateFile(in: metadata)
        let maximumStateBytes = 1_048_576
        var oversized = Data(#"{"favorites":[],"schemaVersion":1}"#.utf8)
        oversized.append(
            Data(repeating: 0x20, count: maximumStateBytes + 1 - oversized.count)
        )
        try write(oversized, to: state)
        let store = try FileUserStateStore(metadataDirectory: metadata)

        await assertThrows(.stateFileTooLarge) {
            _ = try await store.favoritePaths()
        }

        XCTAssertEqual(try Data(contentsOf: state), oversized)
    }

    func testWritesOnlyInsideTheMetadataDirectorySuppliedByTheCaller() async throws {
        let vaultRoot = try makeDirectory()
        let selectedMetadata = vaultRoot.appendingPathComponent(
            "CallerSelectedMetadata",
            isDirectory: true
        )
        let conventionalMetadata = vaultRoot.appendingPathComponent(
            "Metadata",
            isDirectory: true
        )
        let files = vaultRoot.appendingPathComponent("Files", isDirectory: true)
        try createDirectory(selectedMetadata)
        try createDirectory(conventionalMetadata)
        try createDirectory(files)
        let sentinelState = stateFile(in: conventionalMetadata)
        let sentinel = Data("must-not-change".utf8)
        try write(sentinel, to: sentinelState)
        let store = try FileUserStateStore(metadataDirectory: selectedMetadata)

        _ = try await store.setFavorite(
            try makePath("OnlyHere.md"),
            isFavorite: true
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stateFile(in: selectedMetadata).path
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinelState), sentinel)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: vaultRoot.appendingPathComponent("user-state.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: files.appendingPathComponent("user-state.json").path
            )
        )
    }

    func testRejectsANonFileMetadataURL() throws {
        let metadata = try XCTUnwrap(
            URL(string: "https://example.invalid/Metadata")
        )

        XCTAssertThrowsError(
            try FileUserStateStore(metadataDirectory: metadata)
        ) {
            XCTAssertEqual(
                $0 as? FileUserStateStoreError,
                .invalidMetadataDirectory
            )
        }
    }

    func testRejectsAMissingMetadataDirectory() throws {
        let parent = try makeDirectory()
        let missing = parent.appendingPathComponent(
            "MissingMetadata",
            isDirectory: true
        )

        XCTAssertThrowsError(
            try FileUserStateStore(metadataDirectory: missing)
        ) {
            XCTAssertEqual(
                $0 as? FileUserStateStoreError,
                .unavailableMetadataDirectory
            )
        }
    }

    func testRejectsARegularFileAsTheMetadataDirectory() throws {
        let parent = try makeDirectory()
        let file = parent.appendingPathComponent("Metadata")
        try write(Data(), to: file)

        XCTAssertThrowsError(
            try FileUserStateStore(metadataDirectory: file)
        ) {
            XCTAssertEqual(
                $0 as? FileUserStateStoreError,
                .metadataDirectoryIsNotDirectory
            )
        }
    }

    func testRejectsASymbolicLinkAsTheMetadataDirectory() throws {
        let parent = try makeDirectory()
        let actual = parent.appendingPathComponent("Actual", isDirectory: true)
        let link = parent.appendingPathComponent("Metadata", isDirectory: true)
        try createDirectory(actual)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: actual
        )

        XCTAssertThrowsError(
            try FileUserStateStore(metadataDirectory: link)
        ) {
            XCTAssertEqual(
                $0 as? FileUserStateStoreError,
                .metadataDirectoryIsSymbolicLink
            )
        }
    }

    func testRejectsAReplacementDirectoryAtTheSameMetadataPath() async throws {
        let parent = try makeDirectory()
        let metadata = parent.appendingPathComponent("Metadata", isDirectory: true)
        let original = parent.appendingPathComponent(
            "OriginalMetadata",
            isDirectory: true
        )
        try createDirectory(metadata)
        let store = try FileUserStateStore(metadataDirectory: metadata)
        try FileManager.default.moveItem(at: metadata, to: original)
        try createDirectory(metadata)

        await assertThrows(.metadataDirectoryChanged) {
            _ = try await store.favoritePaths()
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile(in: metadata).path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile(in: original).path)
        )
    }

    func testStateFileSymbolicLinkIsNeverReadOrOverwritten() async throws {
        let parent = try makeDirectory()
        let metadata = parent.appendingPathComponent("Metadata", isDirectory: true)
        try createDirectory(metadata)
        let target = parent.appendingPathComponent("stable-target.json")
        let stable = Data(
            #"{"favorites":["stable.md"],"schemaVersion":1}"#.utf8
        )
        try write(stable, to: target)
        let store = try FileUserStateStore(metadataDirectory: metadata)
        try FileManager.default.createSymbolicLink(
            at: stateFile(in: metadata),
            withDestinationURL: target
        )
        let attempted = try makePath("Attempted.md")

        await assertThrows(.stateFileIsNotRegular) {
            _ = try await store.favoritePaths()
        }
        await assertThrows(.stateFileIsNotRegular) {
            _ = try await store.setFavorite(attempted, isFavorite: true)
        }

        XCTAssertEqual(try Data(contentsOf: target), stable)
    }

    func testDirectoryAtStateFilePathFailsClosed() async throws {
        let metadata = try makeDirectory()
        let store = try FileUserStateStore(metadataDirectory: metadata)
        let state = stateFile(in: metadata)
        try createDirectory(state)
        let attempted = try makePath("Attempted.md")

        await assertThrows(.stateFileIsNotRegular) {
            _ = try await store.favoritePaths()
        }
        await assertThrows(.stateFileIsNotRegular) {
            _ = try await store.setFavorite(attempted, isFavorite: true)
        }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: state.path,
                isDirectory: &isDirectory
            )
        )
        XCTAssertTrue(isDirectory.boolValue)
    }
}

extension FileUserStateStoreTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func createDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    private func stateFile(in metadataDirectory: URL) -> URL {
        metadataDirectory.appendingPathComponent("user-state.json")
    }

    private func makePath(_ value: String) throws -> VaultPath {
        try VaultPath(decodedRelativePath: value)
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func assertThrows(
        _ expected: FileUserStateStoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? FileUserStateStoreError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
