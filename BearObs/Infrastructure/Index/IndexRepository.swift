import Foundation
import GRDB

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
#endif

public enum IndexNoteInputError: Error, Equatable, Sendable {
    case byteSizeMismatch(expected: Int64, actual: Int64)
    case invalidModifiedAt
}

public struct IndexNoteInput: Sendable {
    struct Tag: Sendable {
        let normalizedName: String
        let displayName: String
    }

    struct Link: Sendable {
        let rawTarget: String
        let alias: String?
        let sourceRange: Range<Int>
    }

    struct Attachment: Sendable {
        let rawTarget: String
        let sourceRange: Range<Int>
    }

    public let path: VaultPath
    public let contentHash: ContentHash
    public let modifiedAt: Date
    public let byteSize: Int64
    let title: String
    let preview: String
    let body: String
    let parseStatus: String
    let diagnostics: [String]
    let tags: [Tag]
    let links: [Link]
    let attachments: [Attachment]

    public init(
        path: VaultPath,
        parsedNote: ParsedNote,
        contentHash: ContentHash,
        modifiedAt: Date,
        byteSize: Int64
    ) throws {
        let actualByteSize = Int64(parsedNote.frontmatter.originalData.count)
        guard byteSize == actualByteSize else {
            throw IndexNoteInputError.byteSizeMismatch(
                expected: actualByteSize,
                actual: byteSize
            )
        }
        guard modifiedAt.timeIntervalSince1970.isFinite else {
            throw IndexNoteInputError.invalidModifiedAt
        }

        self.path = path
        self.contentHash = contentHash
        self.modifiedAt = modifiedAt
        self.byteSize = byteSize
        title = parsedNote.title
        preview = parsedNote.preview
        body = String(decoding: parsedNote.frontmatter.bodyData, as: UTF8.self)
        switch parsedNote.status {
        case .complete:
            parseStatus = "complete"
        case .degraded:
            parseStatus = "degraded"
        }
        diagnostics = parsedNote.diagnostics.map(\.rawValue)
        tags = parsedNote.tags.map {
            Tag(normalizedName: $0.normalizedName, displayName: $0.displayName)
        }
        links = parsedNote.syntax.wikiLinks.map {
            Link(rawTarget: $0.target, alias: $0.alias, sourceRange: $0.sourceRange)
        }
        attachments = parsedNote.syntax.embeds.map {
            Attachment(rawTarget: $0.target, sourceRange: $0.sourceRange)
        }
    }
}

public struct IndexedNoteFingerprint: Equatable, Sendable {
    public let path: VaultPath
    public let contentHash: ContentHash
    public let modifiedAt: Date
    public let byteSize: Int64
    public let parseStatus: String
}

enum PreparedIndexEntry: Sendable {
    case note(IndexNoteInput)
    case failure(
        path: VaultPath,
        contentHash: ContentHash,
        modifiedAt: Date,
        byteSize: Int64,
        diagnostic: String
    )
}

public final class SQLiteIndexRepository: Sendable {
    let databasePool: DatabasePool

    public init(path: String) throws {
        let databasePool = try DatabasePool(
            path: path,
            configuration: IndexDatabaseConfiguration.make()
        )
        try IndexMigrations.makeMigrator().migrate(databasePool)
        self.databasePool = databasePool
    }

    public func replace(_ input: IndexNoteInput) async throws {
        try await databasePool.write { database in
            let affectedTags = try tagNames(at: input.path, in: database)
                .union(input.tags.map(\.normalizedName))
            try replace(input, in: database)
            try normalizeTags(affectedTags, in: database)
        }
    }

    public func remove(_ path: VaultPath) async throws {
        try await databasePool.write { database in
            let affectedTags = try tagNames(at: path, in: database)
            try database.execute(
                sql: "DELETE FROM note_fts WHERE path = ?",
                arguments: [path.description]
            )
            try database.execute(
                sql: "DELETE FROM note_cjk_fts WHERE path = ?",
                arguments: [path.description]
            )
            try database.execute(
                sql: "DELETE FROM notes WHERE path = ?",
                arguments: [path.description]
            )
            try normalizeTags(affectedTags, in: database)
        }
    }

    public func fingerprints() async throws -> [VaultPath: IndexedNoteFingerprint] {
        try await databasePool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT path, content_hash, modified_at, byte_size, parse_status
                    FROM notes
                    """
            )
            return try Dictionary(
                uniqueKeysWithValues: rows.map { row in
                    let path = try VaultPath(decodedRelativePath: row["path"])
                    let fingerprint = IndexedNoteFingerprint(
                        path: path,
                        contentHash: try ContentHash(hex: row["content_hash"]),
                        modifiedAt: Date(timeIntervalSince1970: row["modified_at"]),
                        byteSize: row["byte_size"],
                        parseStatus: row["parse_status"]
                    )
                    return (path, fingerprint)
                })
        }
    }

    public func refreshMetadata(
        for path: VaultPath,
        matching contentHash: ContentHash,
        modifiedAt: Date,
        byteSize: Int64
    ) async throws -> Bool {
        guard modifiedAt.timeIntervalSince1970.isFinite else {
            throw IndexNoteInputError.invalidModifiedAt
        }
        return try await databasePool.write { database in
            try database.execute(
                sql: """
                    UPDATE notes
                    SET modified_at = ?, byte_size = ?
                    WHERE path = ? AND content_hash = ?
                    """,
                arguments: [
                    modifiedAt.timeIntervalSince1970,
                    byteSize,
                    path.description,
                    contentHash.hex,
                ]
            )
            return database.changesCount == 1
        }
    }

    public func replaceFailure(
        at path: VaultPath,
        contentHash: ContentHash,
        modifiedAt: Date,
        byteSize: Int64,
        diagnostic: String
    ) async throws {
        guard modifiedAt.timeIntervalSince1970.isFinite else {
            throw IndexNoteInputError.invalidModifiedAt
        }
        try await databasePool.write { database in
            let affectedTags = try tagNames(at: path, in: database)
            try replaceFailure(
                at: path,
                contentHash: contentHash,
                modifiedAt: modifiedAt,
                byteSize: byteSize,
                diagnostic: diagnostic,
                in: database
            )
            try normalizeTags(affectedTags, in: database)
        }
    }

    func replaceAll<Source: Sendable>(
        _ sources: [Source],
        prepare: @escaping @Sendable (Source) throws -> PreparedIndexEntry
    ) async throws -> FullIndexRebuildReport {
        try await databasePool.write { database in
            try database.execute(sql: "DELETE FROM note_fts")
            try database.execute(sql: "DELETE FROM note_cjk_fts")
            try database.execute(sql: "DELETE FROM notes")
            try database.execute(sql: "DELETE FROM tags")
            var indexed = 0
            var failed = 0
            for source in sources {
                try Task.checkCancellation()
                let entry = try prepare(source)
                switch entry {
                case .note(let input):
                    try replace(input, in: database)
                    indexed += 1
                case .failure(let path, let hash, let modifiedAt, let byteSize, let diagnostic):
                    try replaceFailure(
                        at: path,
                        contentHash: hash,
                        modifiedAt: modifiedAt,
                        byteSize: byteSize,
                        diagnostic: diagnostic,
                        in: database
                    )
                    failed += 1
                }
            }
            try normalizeTags(in: database)
            return FullIndexRebuildReport(indexed: indexed, failed: failed)
        }
    }
}

extension SQLiteIndexRepository {
    private func tagNames(at path: VaultPath, in database: Database) throws -> Set<String> {
        try Set(
            String.fetchAll(
                database,
                sql: "SELECT tag_name FROM note_tags WHERE note_path = ?",
                arguments: [path.description]
            )
        )
    }

    private func replace(_ input: IndexNoteInput, in database: Database) throws {
        try upsertNote(input, in: database)
        try deleteOccurrences(at: input.path, in: database)
        try insertTags(input.tags, at: input.path, in: database)
        try insertLinks(input.links, at: input.path, in: database)
        try insertAttachments(input.attachments, at: input.path, in: database)
        try insertDiagnostics(input.diagnostics, at: input.path, in: database)
        try insertFTS(input, in: database)
    }

    private func replaceFailure(
        at path: VaultPath,
        contentHash: ContentHash,
        modifiedAt: Date,
        byteSize: Int64,
        diagnostic: String,
        in database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO notes (
                    path, title, preview, content_hash, modified_at, byte_size,
                    parse_status
                ) VALUES (?, ?, '', ?, ?, ?, 'failed')
                ON CONFLICT(path) DO UPDATE SET
                    title = excluded.title,
                    preview = '',
                    content_hash = excluded.content_hash,
                    modified_at = excluded.modified_at,
                    byte_size = excluded.byte_size,
                    parse_status = 'failed'
                """,
            arguments: [
                path.description,
                path.fileNameWithoutExtension,
                contentHash.hex,
                modifiedAt.timeIntervalSince1970,
                byteSize,
            ]
        )
        try deleteOccurrences(at: path, in: database)
        try insertDiagnostics([diagnostic], at: path, in: database)
        try database.execute(
            sql: """
                INSERT INTO note_fts (path, title, body, tags)
                VALUES (?, ?, '', '')
                """,
            arguments: [path.description, path.fileNameWithoutExtension]
        )
        try database.execute(
            sql: """
                INSERT INTO note_cjk_fts (path, title, body, tags)
                VALUES (?, ?, '', '')
                """,
            arguments: [
                path.description,
                IndexCJKSearchText.transform(path.fileNameWithoutExtension),
            ]
        )
    }

    private func upsertNote(_ input: IndexNoteInput, in database: Database) throws {
        try database.execute(
            sql: """
                INSERT INTO notes (
                    path, title, preview, content_hash, modified_at, byte_size, parse_status
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    title = excluded.title,
                    preview = excluded.preview,
                    content_hash = excluded.content_hash,
                    modified_at = excluded.modified_at,
                    byte_size = excluded.byte_size,
                    parse_status = excluded.parse_status
                """,
            arguments: [
                input.path.description,
                input.title,
                input.preview,
                input.contentHash.hex,
                input.modifiedAt.timeIntervalSince1970,
                input.byteSize,
                input.parseStatus,
            ]
        )
    }

    private func deleteOccurrences(at path: VaultPath, in database: Database) throws {
        for statement in [
            "DELETE FROM note_tags WHERE note_path = ?",
            "DELETE FROM links WHERE source_path = ?",
            "DELETE FROM attachments WHERE note_path = ?",
            "DELETE FROM note_diagnostics WHERE note_path = ?",
        ] {
            try database.execute(sql: statement, arguments: [path.description])
        }
        try database.execute(
            sql: "DELETE FROM note_fts WHERE path = ?",
            arguments: [path.description]
        )
        try database.execute(
            sql: "DELETE FROM note_cjk_fts WHERE path = ?",
            arguments: [path.description]
        )
    }

    private func insertTags(_ tags: [IndexNoteInput.Tag], at path: VaultPath, in database: Database)
        throws
    {
        for tag in tags {
            try database.execute(
                sql: """
                    INSERT INTO tags (normalized_name, display_name)
                    VALUES (?, ?)
                    ON CONFLICT(normalized_name) DO NOTHING
                    """,
                arguments: [tag.normalizedName, tag.displayName]
            )
            try database.execute(
                sql: """
                    INSERT INTO note_tags (note_path, tag_name, display_name)
                    VALUES (?, ?, ?)
                    """,
                arguments: [path.description, tag.normalizedName, tag.displayName]
            )
        }
    }

    private func insertLinks(
        _ links: [IndexNoteInput.Link],
        at path: VaultPath,
        in database: Database
    ) throws {
        for link in links {
            try database.execute(
                sql: """
                    INSERT INTO links (
                        source_path, raw_target, alias, source_start, source_end,
                        resolution_state
                    ) VALUES (?, ?, ?, ?, ?, 'unresolved')
                    """,
                arguments: [
                    path.description,
                    link.rawTarget,
                    link.alias,
                    link.sourceRange.lowerBound,
                    link.sourceRange.upperBound,
                ]
            )
        }
    }

    private func insertAttachments(
        _ attachments: [IndexNoteInput.Attachment],
        at path: VaultPath,
        in database: Database
    ) throws {
        for attachment in attachments {
            try database.execute(
                sql: """
                    INSERT INTO attachments (
                        note_path, raw_target, source_start, source_end, cache_state
                    ) VALUES (?, ?, ?, ?, 'not_cached')
                    """,
                arguments: [
                    path.description,
                    attachment.rawTarget,
                    attachment.sourceRange.lowerBound,
                    attachment.sourceRange.upperBound,
                ]
            )
        }
    }

    private func insertDiagnostics(
        _ diagnostics: [String],
        at path: VaultPath,
        in database: Database
    ) throws {
        for code in diagnostics {
            try database.execute(
                sql: """
                    INSERT INTO note_diagnostics (note_path, code)
                    VALUES (?, ?)
                    """,
                arguments: [path.description, code]
            )
        }
    }

    private func insertFTS(_ input: IndexNoteInput, in database: Database) throws {
        let tags = input.tags.map(\.displayName).joined(separator: " ")
        try database.execute(
            sql: """
                INSERT INTO note_fts (path, title, body, tags)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                input.path.description,
                input.title,
                input.body,
                tags,
            ]
        )
        try database.execute(
            sql: """
                INSERT INTO note_cjk_fts (path, title, body, tags)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                input.path.description,
                IndexCJKSearchText.transform(input.title),
                IndexCJKSearchText.transform(input.body),
                IndexCJKSearchText.transform(tags),
            ]
        )
    }

    private func normalizeTags(in database: Database) throws {
        try database.execute(
            sql: """
                DELETE FROM tags
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM note_tags
                    WHERE note_tags.tag_name = tags.normalized_name
                )
                """
        )
        try database.execute(
            sql: """
                UPDATE tags
                SET display_name = (
                    SELECT note_tags.display_name
                    FROM note_tags
                    WHERE note_tags.tag_name = tags.normalized_name
                    ORDER BY note_tags.display_name COLLATE BINARY
                    LIMIT 1
                )
                """
        )
    }

    private func normalizeTags(_ names: Set<String>, in database: Database) throws {
        for name in names {
            let displayName = try String.fetchOne(
                database,
                sql: """
                    SELECT display_name
                    FROM note_tags
                    WHERE tag_name = ?
                    ORDER BY display_name COLLATE BINARY
                    LIMIT 1
                    """,
                arguments: [name]
            )
            if let displayName {
                try database.execute(
                    sql: "UPDATE tags SET display_name = ? WHERE normalized_name = ?",
                    arguments: [displayName, name]
                )
            } else {
                try database.execute(
                    sql: "DELETE FROM tags WHERE normalized_name = ?",
                    arguments: [name]
                )
            }
        }
    }
}
