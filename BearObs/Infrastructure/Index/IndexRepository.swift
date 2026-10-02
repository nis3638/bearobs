import Foundation
import GRDB

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsLocalVault
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

public enum IndexAvailabilityDiagnostic: String, Equatable, Sendable {
    case sourceTemporarilyUnavailable = "index.source-temporarily-unavailable"
}

public struct IndexAvailabilityState: Equatable, Sendable {
    public let unavailableCount: Int
    public let staleNotePaths: Set<VaultPath>

    public init(unavailableCount: Int, staleNotePaths: Set<VaultPath>) {
        self.unavailableCount = unavailableCount
        self.staleNotePaths = staleNotePaths
    }

    public var diagnostic: IndexAvailabilityDiagnostic? {
        unavailableCount > 0 ? .sourceTemporarilyUnavailable : nil
    }
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

    var path: VaultPath {
        switch self {
        case .note(let input):
            input.path
        case .failure(let path, _, _, _, _):
            path
        }
    }
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

    public func replaceAndResolveWikiLinks(_ input: IndexNoteInput) async throws {
        try Task.checkCancellation()
        try await databasePool.write { database in
            let affectedTags = try tagNames(at: input.path, in: database)
                .union(input.tags.map(\.normalizedName))
            try replace(input, in: database)
            try normalizeTags(affectedTags, in: database)
            try resolveWikiLinks(from: input.path, in: database)
        }
        try Task.checkCancellation()
    }

    public func remove(_ path: VaultPath) async throws {
        try await databasePool.write { database in
            let affectedTags = try tagNames(at: path, in: database)
            try remove(path, in: database)
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

    public func fingerprint(at path: VaultPath) async throws -> IndexedNoteFingerprint? {
        try await databasePool.read { database in
            guard
                let row = try Row.fetchOne(
                    database,
                    sql: """
                        SELECT path, content_hash, modified_at, byte_size, parse_status
                        FROM notes
                        WHERE path = ?
                        """,
                    arguments: [path.description]
                )
            else { return nil }
            return IndexedNoteFingerprint(
                path: try VaultPath(decodedRelativePath: row["path"]),
                contentHash: try ContentHash(hex: row["content_hash"]),
                modifiedAt: Date(timeIntervalSince1970: row["modified_at"]),
                byteSize: row["byte_size"],
                parseStatus: row["parse_status"]
            )
        }
    }

    public func availabilityState() async throws -> IndexAvailabilityState {
        try await databasePool.read { database in
            try availabilityState(in: database)
        }
    }

    @discardableResult
    func updateAvailability(
        unavailablePaths: Set<VaultPath>,
        readablePaths: Set<VaultPath>,
        inventoryComplete: Bool
    ) async throws -> IndexAvailabilityState {
        try await databasePool.write { database in
            try updateAvailability(
                unavailablePaths: unavailablePaths,
                readablePaths: readablePaths,
                inventoryComplete: inventoryComplete,
                in: database
            )
            return try availabilityState(in: database)
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

    func replaceAll(
        _ files: [LocalVaultFileMetadata],
        retaining initiallyUnavailablePaths: Set<VaultPath>,
        removeMissing: Bool,
        prepare: @escaping @Sendable (LocalVaultFileMetadata) throws -> PreparedIndexEntry?
    ) async throws -> FullIndexRebuildReport {
        try Task.checkCancellation()
        return try await databasePool.write { database in
            var indexed = 0
            var parseFailures = 0
            var unavailablePaths = initiallyUnavailablePaths
            var readablePaths: Set<VaultPath> = []
            for file in files {
                try Task.checkCancellation()
                guard let entry = try prepare(file) else {
                    unavailablePaths.insert(file.path)
                    continue
                }
                unavailablePaths.remove(file.path)
                readablePaths.insert(entry.path)
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
                    parseFailures += 1
                }
            }
            if removeMissing {
                let currentPaths = readablePaths.union(unavailablePaths)
                let storedPaths = try String.fetchAll(database, sql: "SELECT path FROM notes")
                    .map { try VaultPath(decodedRelativePath: $0) }
                for path in storedPaths where !currentPaths.contains(path) {
                    try Task.checkCancellation()
                    try remove(path, in: database)
                }
            }
            try updateAvailability(
                unavailablePaths: unavailablePaths,
                readablePaths: readablePaths,
                inventoryComplete: removeMissing,
                in: database
            )
            try normalizeTags(in: database)
            try resolveWikiLinks(in: database)
            return FullIndexRebuildReport(
                indexed: indexed,
                failed: parseFailures + unavailablePaths.count
            )
        }
    }
}

extension SQLiteIndexRepository {
    private var unavailableDiagnostic: String {
        IndexAvailabilityDiagnostic.sourceTemporarilyUnavailable.rawValue
    }

    private func availabilityState(in database: Database) throws -> IndexAvailabilityState {
        let unavailableCount =
            try Int.fetchOne(
                database,
                sql: "SELECT unavailable_count FROM index_availability WHERE singleton = 1"
            ) ?? 0
        let staleNotePaths = try Set(
            String.fetchAll(
                database,
                sql: "SELECT note_path FROM note_diagnostics WHERE code = ?",
                arguments: [unavailableDiagnostic]
            ).map { try VaultPath(decodedRelativePath: $0) }
        )
        return IndexAvailabilityState(
            unavailableCount: unavailableCount,
            staleNotePaths: staleNotePaths
        )
    }

    private func updateAvailability(
        unavailablePaths: Set<VaultPath>,
        readablePaths: Set<VaultPath>,
        inventoryComplete: Bool,
        in database: Database
    ) throws {
        if inventoryComplete {
            try database.execute(
                sql: "DELETE FROM note_diagnostics WHERE code = ?",
                arguments: [unavailableDiagnostic]
            )
        } else {
            for path in readablePaths {
                try database.execute(
                    sql: "DELETE FROM note_diagnostics WHERE note_path = ? AND code = ?",
                    arguments: [path.description, unavailableDiagnostic]
                )
            }
        }
        for path in unavailablePaths {
            try database.execute(
                sql: """
                    INSERT INTO note_diagnostics (note_path, code)
                    SELECT path, ? FROM notes WHERE path = ?
                    ON CONFLICT(note_path, code) DO NOTHING
                    """,
                arguments: [unavailableDiagnostic, path.description]
            )
        }
        let countExpression = inventoryComplete ? "?" : "MAX(unavailable_count, ?)"
        try database.execute(
            sql: """
                UPDATE index_availability
                SET unavailable_count = \(countExpression)
                WHERE singleton = 1
                """,
            arguments: [unavailablePaths.count]
        )
    }

    private func remove(_ path: VaultPath, in database: Database) throws {
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
    }

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
