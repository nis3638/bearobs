import Foundation
import GRDB
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsIndex
#else
    @testable import BearObs
#endif

final class IndexSchemaTests: XCTestCase {
    func testFreshDatabaseCreatesTheCompleteSchema() throws {
        let queue = try makeDatabaseQueue()

        try IndexMigrations.makeMigrator().migrate(queue)

        let tables = try queue.read { database in
            try Set(
                String.fetchAll(
                    database,
                    sql: """
                        SELECT name
                        FROM sqlite_master
                        WHERE type IN ('table', 'view')
                        """
                )
            )
        }
        XCTAssertTrue(
            Set([
                "notes", "tags", "note_tags", "links", "attachments", "note_fts",
                "note_cjk_fts", "note_diagnostics",
            ])
            .isSubset(of: tables)
        )
        XCTAssertEqual(
            try appliedMigrations(in: queue),
            [
                "v1_create_index_tables", "v2_create_note_fts",
                "v3_upgrade_occurrence_metadata", "v4_create_cjk_note_fts",
                "v5_create_note_diagnostics",
            ]
        )
        let noteTagColumns = try queue.read { database in
            try String.fetchAll(database, sql: "SELECT name FROM pragma_table_info('note_tags')")
        }
        XCTAssertTrue(noteTagColumns.contains("display_name"))
    }

    func testV2BackfillsExistingNotesAndTagsWithUnicode61() throws {
        let queue = try makeDatabaseQueue()
        let migrator = IndexMigrations.makeMigrator()
        try migrator.migrate(queue, upTo: "v1_create_index_tables")
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO notes (
                        path, title, preview, content_hash, modified_at, byte_size, parse_status
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    "legacy.md", "Café 索引", "migration backfill marker",
                    String(repeating: "a", count: 64), 42.5,
                    128, "complete",
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO tags (normalized_name, display_name)
                    VALUES ('database', 'Database'), ('swift', 'Swift')
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO note_tags (note_path, tag_name)
                    VALUES
                        ('legacy.md', 'swift'),
                        ('legacy.md', 'database')
                    """
            )
        }

        try migrator.migrate(queue)

        let hits = try queue.read { database in
            try String.fetchAll(
                database,
                sql: """
                    SELECT path
                    FROM note_fts
                    WHERE note_fts MATCH 'cafe AND backfill AND database'
                    """
            )
        }
        let createSQL = try queue.read { database in
            try String.fetchOne(
                database,
                sql: "SELECT sql FROM sqlite_master WHERE name = 'note_fts'"
            )
        }
        XCTAssertEqual(hits, ["legacy.md"])
        XCTAssertTrue(createSQL?.lowercased().contains("unicode61") == true)
        let cjkHits = try queue.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT path FROM note_cjk_fts WHERE note_cjk_fts MATCH ?",
                arguments: [FTS5Pattern(matchingPhrase: IndexCJKSearchText.transform("索"))!]
            )
        }
        XCTAssertEqual(cjkHits, ["legacy.md"])
    }

    func testMigrationsAreIdempotentAcrossDatabaseReopen() throws {
        let databaseURL = try makeDatabaseURL()
        let migrator = IndexMigrations.makeMigrator()

        do {
            let firstOpen = try makeDatabaseQueue(at: databaseURL)
            try migrator.migrate(firstOpen)
        }
        let secondOpen = try makeDatabaseQueue(at: databaseURL)
        try migrator.migrate(secondOpen)

        XCTAssertEqual(
            try appliedMigrations(in: secondOpen),
            [
                "v1_create_index_tables", "v2_create_note_fts",
                "v3_upgrade_occurrence_metadata", "v4_create_cjk_note_fts",
                "v5_create_note_diagnostics",
            ]
        )
        let ftsCount = try secondOpen.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE name = 'note_fts'"
            )
        }
        XCTAssertEqual(ftsCount, 1)
    }

    func testFailedV2MigrationIsNotMarkedAsApplied() throws {
        let queue = try makeDatabaseQueue()
        let migrator = IndexMigrations.makeMigrator()
        try migrator.migrate(queue, upTo: "v1_create_index_tables")
        try queue.write { database in
            try database.execute(sql: "CREATE TABLE note_fts (collision TEXT NOT NULL)")
        }

        XCTAssertThrowsError(try migrator.migrate(queue))

        XCTAssertEqual(try appliedMigrations(in: queue), ["v1_create_index_tables"])
    }

    func testV3UpgradesAlreadyMigratedOccurrenceTablesWithoutLosingData() throws {
        let queue = try makeDatabaseQueue()
        let migrator = IndexMigrations.makeMigrator()
        try migrator.migrate(queue, upTo: "v2_create_note_fts")
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO notes (
                        path, title, preview, content_hash, modified_at, byte_size, parse_status
                    ) VALUES (
                        'legacy.md', 'Legacy', '',
                        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                        0, 1, 'complete'
                    )
                    """
            )
            try database.execute(
                sql: "INSERT INTO tags VALUES ('swift', 'Swift')"
            )
            try database.execute(
                sql: "INSERT INTO note_tags VALUES ('legacy.md', 'swift')"
            )
            try database.execute(
                sql: """
                    INSERT INTO links (
                        source_path, raw_target, source_start, source_end, resolution_state
                    ) VALUES ('legacy.md', 'Target', 1, 2, 'missing')
                    """
            )
        }

        try migrator.migrate(queue, upTo: "v3_upgrade_occurrence_metadata")

        let displayName = try queue.read { database in
            try String.fetchOne(database, sql: "SELECT display_name FROM note_tags")
        }
        XCTAssertEqual(displayName, "Swift")
        XCTAssertNoThrow(
            try queue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO links (
                            source_path, raw_target, source_start, source_end, resolution_state
                        ) VALUES ('legacy.md', 'Later', 3, 4, 'unresolved')
                        """
                )
            }
        )
        let links = try queue.read { database in
            try String.fetchAll(database, sql: "SELECT raw_target FROM links ORDER BY id")
        }
        XCTAssertEqual(links, ["Target", "Later"])
    }

    func testRelationalConstraintsRejectInvalidDerivedData() throws {
        let queue = try makeDatabaseQueue()
        try IndexMigrations.makeMigrator().migrate(queue)

        XCTAssertThrowsError(
            try queue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO notes (
                            path, title, preview, content_hash, modified_at, byte_size, parse_status
                        ) VALUES (
                            'bad.md', 'Bad', '',
                            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                            0, -1, 'complete'
                        )
                        """
                )
            }
        )
        XCTAssertThrowsError(
            try queue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO notes (
                            path, title, preview, content_hash, modified_at, byte_size, parse_status
                        ) VALUES (
                            'bad.md', 'Bad', '',
                            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                            0, 1, 'unknown'
                        )
                        """
                )
            }
        )
    }

    func testDeletingANoteCascadesAllOccurrenceRows() throws {
        let queue = try makeDatabaseQueue()
        try IndexMigrations.makeMigrator().migrate(queue)
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO notes (
                        path, title, preview, content_hash, modified_at, byte_size, parse_status
                        ) VALUES (
                            'source.md', 'Source', '',
                            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                            0, 1, 'complete'
                        )
                    """
            )
            try database.execute(
                sql: "INSERT INTO tags (normalized_name, display_name) VALUES ('swift', 'Swift')"
            )
            try database.execute(
                sql: """
                    INSERT INTO note_tags (note_path, tag_name, display_name)
                    VALUES ('source.md', 'swift', 'Swift')
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO links (
                        source_path, raw_target, source_start, source_end, resolution_state
                    ) VALUES ('source.md', 'Target', 4, 14, 'missing')
                    """
            )
            try database.execute(
                sql: """
                    INSERT INTO attachments (
                        note_path, raw_target, source_start, source_end, cache_state
                    ) VALUES ('source.md', 'image.png', 20, 34, 'not_cached')
                    """
            )

            try database.execute(sql: "DELETE FROM notes WHERE path = 'source.md'")
        }

        let counts = try queue.read { database in
            try ["note_tags", "links", "attachments"].map { table in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0])
    }

    func testOccurrenceRangesAndStatesAreConstrained() throws {
        let queue = try makeDatabaseQueue()
        try IndexMigrations.makeMigrator().migrate(queue)
        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO notes (
                        path, title, preview, content_hash, modified_at, byte_size, parse_status
                        ) VALUES (
                            'source.md', 'Source', '',
                            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                            0, 1, 'complete'
                        )
                    """
            )
        }

        XCTAssertThrowsError(
            try queue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO links (
                            source_path, raw_target, source_start, source_end, resolution_state
                        ) VALUES ('source.md', 'Target', 10, 10, 'missing')
                        """
                )
            }
        )
        XCTAssertThrowsError(
            try queue.write { database in
                try database.execute(
                    sql: """
                        INSERT INTO attachments (
                            note_path, raw_target, source_start, source_end, cache_state
                        ) VALUES ('source.md', 'image.png', 1, 2, 'invented')
                        """
                )
            }
        )

        try queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO links (
                        source_path, raw_target, source_start, source_end, resolution_state
                    ) VALUES
                        ('source.md', 'Target', 10, 20, 'unresolved'),
                        ('source.md', 'Target', 30, 40, 'unresolved')
                    """
            )
        }
        let duplicateTargetCount = try queue.read { database in
            try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM links WHERE raw_target = 'Target'"
            )
        }
        XCTAssertEqual(duplicateTargetCount, 2)
    }

    private func makeDatabaseQueue() throws -> DatabaseQueue {
        try DatabaseQueue(configuration: IndexDatabaseConfiguration.make())
    }

    private func makeDatabaseQueue(at url: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: url.path, configuration: IndexDatabaseConfiguration.make())
    }

    private func makeDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("index.sqlite")
    }

    private func appliedMigrations(in queue: DatabaseQueue) throws -> [String] {
        try queue.read { database in
            try IndexMigrations.makeMigrator().appliedMigrations(database)
        }
    }
}
