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

final class FullIndexRebuildTests: XCTestCase {
    func testRebuildProducesTheSameDerivedStateAsIncrementalIndexing() async throws {
        let fixture = try makeFixture()
        try write("# Alpha\n\nshared [[Beta]] #One", at: fixture.root, path: "alpha.md")
        try write(
            "---\ntitle: Beta\ntags: [Two]\n---\nshared ![[asset.png]]", at: fixture.root,
            path: "beta.md")
        try write("# Stale", at: fixture.root, path: "stale.md")
        _ = try await fixture.rebuildScanner.scan()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("stale.md"))

        let incremental = try await fixture.incrementalScanner.scan()
        let rebuilt = try await fixture.rebuildScanner.rebuild()

        XCTAssertEqual(incremental.indexed, 2)
        XCTAssertEqual(rebuilt, .init(indexed: 2))
        let incrementalSnapshot = try await snapshot(fixture.incrementalRepository)
        let rebuildSnapshot = try await snapshot(fixture.rebuildRepository)
        XCTAssertEqual(incrementalSnapshot, rebuildSnapshot)
    }

    func testRebuildFailureRollsBackAndPreservesThePreviousIndex() async throws {
        let fixture = try makeFixture()
        try write("# Old\n\noldterm", at: fixture.root, path: "old.md")
        _ = try await fixture.rebuildScanner.scan()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("old.md"))
        try write("# Blocked\n\nnewterm", at: fixture.root, path: "blocked.md")
        try await fixture.rebuildRepository.databasePool.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_rebuild
                    BEFORE INSERT ON notes
                    WHEN NEW.path = 'blocked.md'
                    BEGIN
                        SELECT RAISE(ABORT, 'injected rebuild failure');
                    END
                    """
            )
        }

        do {
            _ = try await fixture.rebuildScanner.rebuild()
            XCTFail("Expected rebuild to fail")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }

        let oldHits = try await fixture.rebuildRepository.search("oldterm")
        let newHits = try await fixture.rebuildRepository.search("newterm")
        XCTAssertEqual(oldHits.map(\.path.description), ["old.md"])
        XCTAssertEqual(newHits, [])
    }
}

extension FullIndexRebuildTests {
    private struct Fixture {
        let root: URL
        let incrementalRepository: SQLiteIndexRepository
        let rebuildRepository: SQLiteIndexRepository
        let incrementalScanner: IncrementalIndexScanner
        let rebuildScanner: IncrementalIndexScanner
    }

    private struct DatabaseSnapshot: Equatable {
        let fingerprints: [VaultPath: IndexedNoteFingerprint]
        let sharedHits: [IndexSearchHit]
        let rowsByTable: [String: [String]]
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = directory.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let incremental = try SQLiteIndexRepository(
            path: directory.appendingPathComponent("incremental.sqlite").path
        )
        let rebuild = try SQLiteIndexRepository(
            path: directory.appendingPathComponent("rebuild.sqlite").path
        )
        return try Fixture(
            root: root,
            incrementalRepository: incremental,
            rebuildRepository: rebuild,
            incrementalScanner: IncrementalIndexScanner(root: root, repository: incremental),
            rebuildScanner: IncrementalIndexScanner(root: root, repository: rebuild)
        )
    }

    private func snapshot(_ repository: SQLiteIndexRepository) async throws -> DatabaseSnapshot {
        let rows = try await repository.databasePool.read { database in
            let queries = [
                "notes": """
                SELECT json_array(path, title, preview, content_hash, modified_at,
                                  byte_size, parse_status) FROM notes ORDER BY path
                """,
                "tags": """
                SELECT json_array(normalized_name, display_name)
                FROM tags ORDER BY normalized_name
                """,
                "note_tags": """
                SELECT json_array(note_path, tag_name, display_name)
                FROM note_tags ORDER BY note_path, tag_name
                """,
                "links": """
                SELECT json_array(source_path, raw_target, alias, source_start,
                                  source_end, resolved_path, resolution_state)
                FROM links ORDER BY source_path, source_start
                """,
                "attachments": """
                SELECT json_array(note_path, raw_target, source_start, source_end,
                                  resolved_path, cache_state)
                FROM attachments ORDER BY note_path, source_start
                """,
                "note_fts": """
                SELECT json_array(path, title, body, tags)
                FROM note_fts ORDER BY path
                """,
                "note_cjk_fts": """
                SELECT json_array(path, title, body, tags)
                FROM note_cjk_fts ORDER BY path
                """,
                "note_diagnostics": """
                SELECT json_array(note_path, code)
                FROM note_diagnostics ORDER BY note_path, code
                """,
            ]
            return try Dictionary(
                uniqueKeysWithValues: queries.map { table, sql in
                    (table, try String.fetchAll(database, sql: sql))
                }
            )
        }
        return DatabaseSnapshot(
            fingerprints: try await repository.fingerprints(),
            sharedHits: try await repository.search("shared"),
            rowsByTable: rows
        )
    }

    private func write(_ content: String, at root: URL, path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }
}
