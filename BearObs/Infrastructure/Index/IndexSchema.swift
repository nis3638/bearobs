import GRDB

enum IndexDatabaseConfiguration {
    static func make() -> Configuration {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return configuration
    }
}

enum IndexMigrations {
    static let createIndexTables = "v1_create_index_tables"
    static let createNoteFTS = "v2_create_note_fts"
    static let upgradeOccurrenceMetadata = "v3_upgrade_occurrence_metadata"
    static let createCJKNoteFTS = "v4_create_cjk_note_fts"
    static let createNoteDiagnostics = "v5_create_note_diagnostics"

    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(createIndexTables, migrate: createTables)
        migrator.registerMigration(createNoteFTS, migrate: createFTS)
        migrator.registerMigration(upgradeOccurrenceMetadata, migrate: upgradeOccurrences)
        migrator.registerMigration(createCJKNoteFTS, migrate: createCJKFTS)
        migrator.registerMigration(createNoteDiagnostics, migrate: createDiagnostics)
        return migrator
    }

    private static func createTables(_ database: Database) throws {
        try database.create(table: "notes") { table in
            table.primaryKey("path", .text)
            table.column("title", .text).notNull()
            table.column("preview", .text).notNull()
            table.column("content_hash", .text).notNull()
            table.column("modified_at", .double).notNull()
            table.column("byte_size", .integer).notNull()
            table.column("parse_status", .text).notNull()
            table.check(sql: "path <> ''")
            table.check(
                sql: """
                    length(content_hash) = 64
                    AND content_hash NOT GLOB '*[^0-9a-f]*'
                    """
            )
            table.check(sql: "byte_size >= 0")
            table.check(sql: "parse_status IN ('complete', 'degraded', 'failed')")
        }

        try database.create(table: "tags") { table in
            table.primaryKey("normalized_name", .text)
            table.column("display_name", .text).notNull()
            table.check(sql: "normalized_name <> ''")
            table.check(sql: "display_name <> ''")
        }

        try database.create(table: "note_tags", options: .withoutRowID) { table in
            table.column("note_path", .text)
                .notNull()
                .references("notes", column: "path", onDelete: .cascade)
            table.column("tag_name", .text)
                .notNull()
                .references("tags", column: "normalized_name", onDelete: .cascade)
            table.primaryKey(["note_path", "tag_name"])
        }

        try database.create(table: "links") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("source_path", .text)
                .notNull()
                .references("notes", column: "path", onDelete: .cascade)
            table.column("raw_target", .text).notNull()
            table.column("alias", .text)
            table.column("source_start", .integer).notNull()
            table.column("source_end", .integer).notNull()
            table.column("resolved_path", .text)
            table.column("resolution_state", .text).notNull()
            table.uniqueKey(["source_path", "source_start"])
            table.check(sql: "raw_target <> ''")
            table.check(sql: "source_start >= 0 AND source_end > source_start")
            table.check(
                sql: "resolution_state IN ('resolved', 'missing', 'ambiguous')"
            )
            table.check(
                sql: """
                    (resolution_state = 'resolved' AND resolved_path IS NOT NULL)
                    OR (resolution_state <> 'resolved' AND resolved_path IS NULL)
                    """
            )
        }

        try database.create(table: "attachments") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("note_path", .text)
                .notNull()
                .references("notes", column: "path", onDelete: .cascade)
            table.column("raw_target", .text).notNull()
            table.column("source_start", .integer).notNull()
            table.column("source_end", .integer).notNull()
            table.column("resolved_path", .text)
            table.column("cache_state", .text).notNull()
            table.uniqueKey(["note_path", "source_start"])
            table.check(sql: "raw_target <> ''")
            table.check(sql: "source_start >= 0 AND source_end > source_start")
            table.check(sql: "cache_state IN ('not_cached', 'available', 'missing')")
        }

        try database.create(indexOn: "notes", columns: ["modified_at"])
        try database.create(indexOn: "note_tags", columns: ["tag_name"])
        try database.create(indexOn: "links", columns: ["resolved_path"])
        try database.create(indexOn: "attachments", columns: ["resolved_path"])
    }

    private static func createFTS(_ database: Database) throws {
        try database.create(virtualTable: "note_fts", using: FTS5()) { table in
            table.tokenizer = .unicode61()
            table.column("path").notIndexed()
            table.column("title")
            table.column("body")
            table.column("tags")
        }
        try database.execute(
            sql: """
                INSERT INTO note_fts (path, title, body, tags)
                SELECT
                    notes.path,
                    notes.title,
                    notes.preview,
                    COALESCE(
                        (
                            SELECT group_concat(ordered_tags.display_name, ' ')
                            FROM (
                                SELECT tags.display_name
                                FROM note_tags
                                JOIN tags ON tags.normalized_name = note_tags.tag_name
                                WHERE note_tags.note_path = notes.path
                                ORDER BY tags.normalized_name COLLATE BINARY
                            ) AS ordered_tags
                        ),
                        ''
                    )
                FROM notes
                """
        )
    }

    private static func createCJKFTS(_ database: Database) throws {
        try database.create(virtualTable: "note_cjk_fts", using: FTS5()) { table in
            table.tokenizer = .unicode61()
            table.column("path").notIndexed()
            table.column("title")
            table.column("body")
            table.column("tags")
        }
        let rows = try Row.fetchCursor(
            database,
            sql: "SELECT path, title, body, tags FROM note_fts"
        )
        let insert = try database.makeStatement(
            sql: """
                INSERT INTO note_cjk_fts (path, title, body, tags)
                VALUES (?, ?, ?, ?)
                """
        )
        while let row = try rows.next() {
            try insert.execute(
                arguments: [
                    row["path"],
                    IndexCJKSearchText.transform(row["title"]),
                    IndexCJKSearchText.transform(row["body"]),
                    IndexCJKSearchText.transform(row["tags"]),
                ]
            )
        }
    }

    private static func createDiagnostics(_ database: Database) throws {
        try database.create(table: "note_diagnostics", options: .withoutRowID) { table in
            table.column("note_path", .text)
                .notNull()
                .references("notes", column: "path", onDelete: .cascade)
            table.column("code", .text).notNull()
            table.primaryKey(["note_path", "code"])
            table.check(sql: "code <> ''")
        }
    }

    private static func upgradeOccurrences(_ database: Database) throws {
        try database.rename(table: "note_tags", to: "note_tags_v2")
        try createCurrentNoteTags(database)
        try database.execute(
            sql: """
                INSERT INTO note_tags (note_path, tag_name, display_name)
                SELECT note_tags_v2.note_path, note_tags_v2.tag_name, tags.display_name
                FROM note_tags_v2
                JOIN tags ON tags.normalized_name = note_tags_v2.tag_name
                """
        )
        try database.drop(table: "note_tags_v2")
        try database.create(indexOn: "note_tags", columns: ["tag_name"])

        try database.rename(table: "links", to: "links_v2")
        try createCurrentLinks(database)
        try database.execute(
            sql: """
                INSERT INTO links (
                    id, source_path, raw_target, alias, source_start, source_end,
                    resolved_path, resolution_state
                )
                SELECT
                    id, source_path, raw_target, alias, source_start, source_end,
                    resolved_path, resolution_state
                FROM links_v2
                """
        )
        try database.drop(table: "links_v2")
        try database.create(indexOn: "links", columns: ["resolved_path"])
    }

    private static func createCurrentNoteTags(_ database: Database) throws {
        try database.create(table: "note_tags", options: .withoutRowID) { table in
            table.column("note_path", .text)
                .notNull()
                .references("notes", column: "path", onDelete: .cascade)
            table.column("tag_name", .text)
                .notNull()
                .references("tags", column: "normalized_name", onDelete: .cascade)
            table.column("display_name", .text).notNull()
            table.primaryKey(["note_path", "tag_name"])
            table.check(sql: "display_name <> ''")
        }
    }

    private static func createCurrentLinks(_ database: Database) throws {
        try database.create(table: "links") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("source_path", .text)
                .notNull()
                .references("notes", column: "path", onDelete: .cascade)
            table.column("raw_target", .text).notNull()
            table.column("alias", .text)
            table.column("source_start", .integer).notNull()
            table.column("source_end", .integer).notNull()
            table.column("resolved_path", .text)
            table.column("resolution_state", .text).notNull()
            table.uniqueKey(["source_path", "source_start"])
            table.check(sql: "raw_target <> ''")
            table.check(sql: "source_start >= 0 AND source_end > source_start")
            table.check(
                sql: "resolution_state IN ('unresolved', 'resolved', 'missing', 'ambiguous')"
            )
            table.check(
                sql: """
                    (resolution_state = 'resolved' AND resolved_path IS NOT NULL)
                    OR (resolution_state <> 'resolved' AND resolved_path IS NULL)
                    """
            )
        }
    }
}
