import Foundation
import GRDB
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsIndex
    import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class IncrementalIndexScannerTests: XCTestCase {
    func testIndexesThenSkipsUnchangedMetadataWithoutReadingAgain() async throws {
        let fixture = try makeFixture()
        try write("# First\n\nbody #One", at: fixture.root, path: "first.md")

        let first = try await fixture.scanner.scan()
        let second = try await fixture.scanner.scan()

        XCTAssertEqual(first, .init(indexed: 1))
        XCTAssertEqual(second, .init(metadataSkipped: 1))
        let row = try await noteRow("first.md", in: fixture.repository)
        XCTAssertEqual(row["title"] as String, "First")
        XCTAssertEqual(row["parse_status"] as String, "complete")
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
        XCTAssertEqual(row["modified_at"] as Double, changedDate.timeIntervalSince1970)
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
        XCTAssertEqual(row["title"] as String, "broken")
        XCTAssertEqual(row["preview"] as String, "")
        XCTAssertEqual(row["parse_status"] as String, "failed")
        let tagCount = try await fixture.repository.databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM note_tags")!
        }
        let fts = try fixture.repository.databasePool.read {
            try Row.fetchOne(
                $0, sql: "SELECT title, body, tags FROM note_fts WHERE path = 'broken.md'")!
        }
        let diagnostics = try await fixture.repository.databasePool.read {
            try String.fetchAll(
                $0,
                sql: "SELECT code FROM note_diagnostics WHERE note_path = 'broken.md'"
            )
        }
        XCTAssertEqual(tagCount, 0)
        XCTAssertEqual(fts["title"] as String, "broken")
        XCTAssertEqual(fts["body"] as String, "")
        XCTAssertEqual(fts["tags"] as String, "")
        XCTAssertEqual(diagnostics, ["markdown.note-too-large"])
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
        XCTAssertEqual(row["title"] as String, "After")
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
        let scanner = try IncrementalIndexScanner(
            root: root,
            repository: repository,
            limits: MarkdownParseLimits(maximumNoteBytes: maximumNoteBytes)
        )
        return Fixture(root: root, repository: repository, scanner: scanner)
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

    private func noteRow(
        _ path: String,
        in repository: SQLiteIndexRepository
    ) async throws -> Row {
        try repository.databasePool.read {
            try Row.fetchOne($0, sql: "SELECT * FROM notes WHERE path = ?", arguments: [path])!
        }
    }
}
