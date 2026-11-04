import CryptoKit
import Darwin
import Foundation
import GRDB
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsIndex
    import BearObsLocalVault
    import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class IncrementalIndexScannerTests: XCTestCase {
    func testSourceSnapshotRoundTripsExactBytesAndRejectsCorruption() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexedSourceSnapshotStore(directory: directory)
        let data =
            Data([0xEF, 0xBB, 0xBF])
            + Data("---\r\ntitle: 中文😀\r\n---\r\n正文\r\n".utf8)
        let hash = try contentHash(data)

        try store.store(data, matching: hash)
        XCTAssertEqual(try store.load(matching: hash), data)

        try Data("corrupt".utf8).write(to: store.fileURL(for: hash))
        XCTAssertThrowsError(try store.load(matching: hash)) { error in
            XCTAssertEqual(error as? IndexedSourceSnapshotStoreError, .contentHashMismatch)
        }
    }

    func testSourceSnapshotRejectsDirectoryReplacementAndSymbolicLinkEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("snapshots", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try IndexedSourceSnapshotStore(directory: directory)
        let data = Data("private note".utf8)
        let hash = try contentHash(data)
        let target = root.appendingPathComponent("target")
        try data.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: store.fileURL(for: hash),
            withDestinationURL: target
        )

        XCTAssertThrowsError(try store.load(matching: hash)) { error in
            XCTAssertEqual(error as? IndexedSourceSnapshotStoreError, .snapshotIsSymbolicLink)
        }
        XCTAssertThrowsError(try store.store(data, matching: hash)) { error in
            XCTAssertEqual(error as? IndexedSourceSnapshotStoreError, .snapshotIsSymbolicLink)
        }

        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.load(matching: hash)) { error in
            XCTAssertEqual(error as? IndexedSourceSnapshotStoreError, .directoryChanged)
        }
    }

    func testCorruptSnapshotCleanupDoesNotDeleteAConcurrentAtomicReplacement() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try IndexedSourceSnapshotStore(directory: directory)
        let data = Data("stable".utf8)
        let hash = try contentHash(data)
        try store.store(data, matching: hash)
        var original = stat()
        XCTAssertEqual(lstat(store.fileURL(for: hash).path, &original), 0)

        try store.store(data, matching: hash)
        try store.removeSnapshotIfUnchanged(
            matching: hash,
            expectedDevice: original.st_dev,
            expectedInode: original.st_ino
        )

        XCTAssertEqual(try store.load(matching: hash), data)
    }

    func testSuccessfulScanStoresSnapshotAndBackfillsMissingLegacyCache() async throws {
        let fixture = try makeFixture()
        let note = try write("# Cached\n\nbody", at: fixture.root, path: "cached.md")
        let data = try Data(contentsOf: note)
        let hash = try contentHash(data)

        let first = try await fixture.scanner.scan()
        XCTAssertEqual(first, .init(indexed: 1))
        XCTAssertEqual(try fixture.snapshots.load(matching: hash), data)

        try FileManager.default.removeItem(at: fixture.snapshots.fileURL(for: hash))
        let second = try await fixture.scanner.scan()

        XCTAssertEqual(second, .init(hashSkipped: 1))
        XCTAssertEqual(try fixture.snapshots.load(matching: hash), data)
    }

    func testCorruptSnapshotIsDiscardedAndNextScanRepairsIt() async throws {
        let fixture = try makeFixture()
        let note = try write("# Repairable", at: fixture.root, path: "repair.md")
        let data = try Data(contentsOf: note)
        let hash = try contentHash(data)
        _ = try await fixture.scanner.scan()
        try Data("corrupt".utf8).write(to: fixture.snapshots.fileURL(for: hash))

        XCTAssertThrowsError(try fixture.snapshots.load(matching: hash))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.snapshots.fileURL(for: hash).path)
        )

        let report = try await fixture.scanner.scan()
        XCTAssertEqual(report, .init(hashSkipped: 1))
        XCTAssertEqual(try fixture.snapshots.load(matching: hash), data)
    }

    func testSnapshotWriteFailureDoesNotBlockThePrimaryIndex() async throws {
        let fixture = try makeFixture()
        try write("# Still indexed", at: fixture.root, path: "note.md")
        let snapshotDirectory = fixture.snapshots.fileURL(
            for: try contentHash(Data("unused".utf8))
        ).deletingLastPathComponent()
        try FileManager.default.removeItem(at: snapshotDirectory)
        try Data("not a directory".utf8).write(to: snapshotDirectory)

        let report = try await fixture.scanner.scan()

        XCTAssertEqual(report, .init(indexed: 1))
        let row = try await noteRow("note.md", in: fixture.repository)
        XCTAssertEqual(row.title, "Still indexed")
    }

    func testIndexesThenSkipsUnchangedMetadataWithoutReadingAgain() async throws {
        let fixture = try makeFixture()
        try write("# First\n\nbody #One", at: fixture.root, path: "first.md")

        let first = try await fixture.scanner.scan()
        let second = try await fixture.scanner.scan()

        XCTAssertEqual(first, .init(indexed: 1))
        XCTAssertEqual(second, .init(metadataSkipped: 1))
        let row = try await noteRow("first.md", in: fixture.repository)
        XCTAssertEqual(row.title, "First")
        XCTAssertEqual(row.parseStatus, "complete")
    }

    func testMetadataChangeWithSameHashSkipsParsingAndRefreshesMetadata() async throws {
        let fixture = try makeFixture()
        let note = try write("# Stable", at: fixture.root, path: "stable.md")
        _ = try await fixture.scanner.scan()
        let changedDate = Date(timeIntervalSince1970: 2_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: changedDate], ofItemAtPath: note.path)

        let report = try await fixture.scanner.scan()

        XCTAssertEqual(report, .init(hashSkipped: 1))
        let row = try await noteRow("stable.md", in: fixture.repository)
        XCTAssertEqual(row.modifiedAt, changedDate.timeIntervalSince1970)
    }

    func testChangedContentIsReindexedAndDeletedFileIsRemoved() async throws {
        let fixture = try makeFixture()
        let note = try write("# Before", at: fixture.root, path: "note.md")
        _ = try await fixture.scanner.scan()
        try write("# After\n\nchanged", to: note)

        let changed = try await fixture.scanner.scan()
        try FileManager.default.removeItem(at: note)
        let deleted = try await fixture.scanner.scan()

        XCTAssertEqual(changed, .init(indexed: 1))
        XCTAssertEqual(deleted, .init(removed: 1))
        let count = try await fixture.repository.databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notes")!
        }
        XCTAssertEqual(count, 0)
    }

    func testFatalParseFailureReplacesStaleDerivationsWithSafeTitle() async throws {
        let fixture = try makeFixture(maximumNoteBytes: 4)
        let note = try write("# Old #tag", at: fixture.root, path: "broken.md")
        _ = try await fixture.scanner.scan()
        try write("12345", to: note)

        let report = try await fixture.scanner.scan()

        XCTAssertEqual(report, .init(failed: 1))
        let row = try await noteRow("broken.md", in: fixture.repository)
        XCTAssertEqual(row.title, "broken")
        XCTAssertEqual(row.preview, "")
        XCTAssertEqual(row.parseStatus, "failed")
        let tagCount = try await fixture.repository.databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_tags")!
        }
        let fts = try await fixture.repository.databasePool.read { db -> (title: String, body: String, tags: String) in
            let row = try Row.fetchOne(
                db, sql: "SELECT title, body, tags FROM note_fts WHERE path = 'broken.md'")!
            return (row["title"], row["body"], row["tags"])
        }
        let diagnostics = try await fixture.repository.databasePool.read {
            try String.fetchAll(
                $0,
                sql: "SELECT code FROM note_diagnostics WHERE note_path = 'broken.md'"
            )
        }
        XCTAssertEqual(tagCount, 0)
        XCTAssertEqual(fts.title, "broken")
        XCTAssertEqual(fts.body, "")
        XCTAssertEqual(fts.tags, "")
        XCTAssertEqual(diagnostics, ["markdown.note-too-large"])
    }

    func testTemporarilyUnavailableInventoryEntryKeepsItsIndexAndDoesNotBlockOthers()
        async throws
    {
        let fixture = try makeFixture()
        try write("# Preserved", at: fixture.root, path: "preserved.md")
        let changed = try write("# Before", at: fixture.root, path: "changed.md")
        _ = try await fixture.scanner.scan()
        try write("# After", to: changed)

        let store = try LocalVaultStore(root: fixture.root)
        let completeInventory = try store.markdownInventory()
        let preservedPath = try VaultPath(decodedRelativePath: "preserved.md")
        let scanner = try IncrementalIndexScanner(
            root: fixture.root,
            repository: fixture.repository,
            limits: .default,
            inventory: {
                LocalVaultMarkdownInventory(
                    readable: completeInventory.readable.filter { $0.path != preservedPath },
                    temporarilyUnavailablePaths: [preservedPath]
                )
            },
            read: store.read
        )

        let report = try await scanner.scan()
        let preservedRow = try await noteRow("preserved.md", in: fixture.repository)
        let changedRow = try await noteRow("changed.md", in: fixture.repository)

        XCTAssertEqual(report, .init(indexed: 1, failed: 1))
        XCTAssertEqual(preservedRow.title, "Preserved")
        XCTAssertEqual(changedRow.title, "After")
    }

    func testReadFailureKeepsItsIndexAndContinuesReadingOtherFiles() async throws {
        let fixture = try makeFixture()
        let unavailable = try write("# Old unavailable", at: fixture.root, path: "a.md")
        let changed = try write("# Before", at: fixture.root, path: "b.md")
        _ = try await fixture.scanner.scan()
        try write("# New unavailable", to: unavailable)
        try write("# After", to: changed)

        let store = try LocalVaultStore(root: fixture.root)
        let unavailablePath = try VaultPath(decodedRelativePath: "a.md")
        let scanner = try IncrementalIndexScanner(
            root: fixture.root,
            repository: fixture.repository,
            limits: .default,
            inventory: store.markdownInventory,
            read: { path, maximumRetainedBytes in
                if path == unavailablePath {
                    throw LocalVaultStoreError.unavailableFile
                }
                return try store.read(path, maximumRetainedBytes: maximumRetainedBytes)
            }
        )

        let report = try await scanner.scan()
        let unavailableRow = try await noteRow("a.md", in: fixture.repository)
        let changedRow = try await noteRow("b.md", in: fixture.repository)

        XCTAssertEqual(report, .init(indexed: 1, failed: 1))
        XCTAssertEqual(unavailableRow.title, "Old unavailable")
        XCTAssertEqual(changedRow.title, "After")
    }

    func testUnavailableStatePersistsAnonymouslyAndClearsAfterRecovery() async throws {
        let fixture = try makeFixture()
        let indexed = try write("# Before", at: fixture.root, path: "indexed.md")
        _ = try await fixture.scanner.scan()
        try write("# After", to: indexed)
        try write("# New", at: fixture.root, path: "private/new.md")

        let store = try LocalVaultStore(root: fixture.root)
        let indexedPath = try VaultPath(decodedRelativePath: "indexed.md")
        let newPath = try VaultPath(decodedRelativePath: "private/new.md")
        let unavailableScanner = try IncrementalIndexScanner(
            root: fixture.root,
            repository: fixture.repository,
            limits: .default,
            inventory: store.markdownInventory,
            read: { path, maximumRetainedBytes in
                if path == indexedPath || path == newPath {
                    throw LocalVaultStoreError.unavailableFile
                }
                return try store.read(path, maximumRetainedBytes: maximumRetainedBytes)
            }
        )

        let unavailableReport = try await unavailableScanner.scan()
        let unavailableState = try await fixture.repository.availabilityState()

        XCTAssertEqual(unavailableReport, .init(failed: 2))
        XCTAssertEqual(
            unavailableState,
            .init(unavailableCount: 2, staleNotePaths: [indexedPath])
        )
        XCTAssertEqual(unavailableState.diagnostic, .sourceTemporarilyUnavailable)

        let recoveredReport = try await fixture.scanner.scan()
        let recoveredState = try await fixture.repository.availabilityState()

        XCTAssertEqual(recoveredReport, .init(indexed: 2))
        XCTAssertEqual(recoveredState, .init(unavailableCount: 0, staleNotePaths: []))
        XCTAssertNil(recoveredState.diagnostic)
    }

    func testIncompleteInventoryIndexesReadableFilesWithoutRemovingMissingEntries()
        async throws
    {
        let fixture = try makeFixture()
        let preserved = try write("# Preserved", at: fixture.root, path: "preserved.md")
        let changed = try write("# Before", at: fixture.root, path: "changed.md")
        _ = try await fixture.scanner.scan()
        try FileManager.default.removeItem(at: preserved)
        try write("# After", to: changed)

        let store = try LocalVaultStore(root: fixture.root)
        let inventory = try store.markdownInventory()
        let scanner = try IncrementalIndexScanner(
            root: fixture.root,
            repository: fixture.repository,
            limits: .default,
            inventory: {
                LocalVaultMarkdownInventory(
                    readable: inventory.readable,
                    temporarilyUnavailablePaths: [],
                    allowsRemoval: false
                )
            },
            read: store.read
        )

        let report = try await scanner.scan()
        let preservedRow = try await noteRow("preserved.md", in: fixture.repository)
        let changedRow = try await noteRow("changed.md", in: fixture.repository)

        XCTAssertEqual(report, .init(indexed: 1))
        XCTAssertEqual(preservedRow.title, "Preserved")
        XCTAssertEqual(changedRow.title, "After")
    }

    func testRefreshUpdatesOneSavedNoteWithoutAFullVaultScan() async throws {
        let fixture = try makeFixture()
        let note = try write("# Before\n\nold body #old", at: fixture.root, path: "note.md")
        try write("# Other\n\n[[note]]", at: fixture.root, path: "other.md")
        _ = try await fixture.scanner.scan()
        try await fixture.repository.databasePool.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_unrelated_link_refresh
                    BEFORE UPDATE ON links
                    WHEN OLD.source_path = 'other.md'
                    BEGIN
                        SELECT RAISE(ABORT, 'unrelated link was refreshed');
                    END
                    """
            )
        }
        try write("# After\n\nnew body #new", to: note)

        try await fixture.scanner.refresh(
            VaultPath(decodedRelativePath: "note.md")
        )

        let row = try await noteRow("note.md", in: fixture.repository)
        XCTAssertEqual(row.title, "After")
        let tags = try await fixture.repository.databasePool.read {
            try String.fetchAll($0, sql: "SELECT normalized_name FROM tags ORDER BY 1")
        }
        XCTAssertEqual(tags, ["new"])
    }
}

extension IncrementalIndexScannerTests {
    private struct Fixture {
        let root: URL
        let repository: SQLiteIndexRepository
        let scanner: IncrementalIndexScanner
        let snapshots: IndexedSourceSnapshotStore
    }

    private func makeFixture(maximumNoteBytes: Int = 1_024 * 1_024) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = directory.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let repository = try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
        let snapshots = try IndexedSourceSnapshotStore(
            directory: directory.appendingPathComponent("ReaderSnapshots", isDirectory: true)
        )
        let scanner = try IncrementalIndexScanner(
            root: root,
            repository: repository,
            limits: MarkdownParseLimits(maximumNoteBytes: maximumNoteBytes),
            snapshots: snapshots
        )
        return Fixture(
            root: root,
            repository: repository,
            scanner: scanner,
            snapshots: snapshots
        )
    }

    @discardableResult
    private func write(_ content: String, at root: URL, path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try write(content, to: url)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }

    private struct NoteRowSnapshot: Sendable {
        let title: String
        let preview: String
        let parseStatus: String
        let modifiedAt: Double
    }

    private func noteRow(
        _ path: String,
        in repository: SQLiteIndexRepository
    ) async throws -> NoteRowSnapshot {
        try await repository.databasePool.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM notes WHERE path = ?", arguments: [path])!
            return NoteRowSnapshot(
                title: row["title"],
                preview: row["preview"],
                parseStatus: row["parse_status"],
                modifiedAt: row["modified_at"])
        }
    }

    private func contentHash(_ data: Data) throws -> ContentHash {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try ContentHash(hex: hex)
    }
}
