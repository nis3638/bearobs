import Foundation
import GRDB

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public enum IndexSearchError: Error, Equatable, Sendable {
    case invalidLimit
    case queryTooLong(maximumCharacters: Int)
    case invalidControlCharacter
}

public struct IndexSearchHit: Equatable, Identifiable, Sendable {
    public var id: VaultPath { path }

    public let path: VaultPath
    public let title: String
    public let preview: String
    public let parseStatus: IndexedNoteParseStatus
    public let modifiedAt: Date

    public init(
        path: VaultPath,
        title: String,
        preview: String,
        parseStatus: IndexedNoteParseStatus,
        modifiedAt: Date
    ) {
        self.path = path
        self.title = title
        self.preview = preview
        self.parseStatus = parseStatus
        self.modifiedAt = modifiedAt
    }
}

extension SQLiteIndexRepository {
    public func search(_ rawQuery: String, limit: Int = 20) async throws -> [IndexSearchHit] {
        guard (1...100).contains(limit) else {
            throw IndexSearchError.invalidLimit
        }
        let query = try normalizedSearchQuery(rawQuery)
        try Task.checkCancellation()

        let hits: [IndexSearchHit]
        if query.isEmpty {
            hits = try await recentNotes(limit: limit)
        } else if IndexCJKSearchText.containsHan(query),
            let pattern = cjkPattern(query)
        {
            hits = try await matchingCJKNotes(pattern, limit: limit)
        } else if let pattern = FTS5Pattern(matchingAllTokensIn: query) {
            hits = try await matchingNotes(pattern, limit: limit)
        } else {
            hits = []
        }
        try Task.checkCancellation()
        return hits
    }
}

extension SQLiteIndexRepository {
    private static let maximumSearchCharacters = 256

    private func normalizedSearchQuery(_ query: String) throws -> String {
        guard query.count <= Self.maximumSearchCharacters else {
            throw IndexSearchError.queryTooLong(
                maximumCharacters: Self.maximumSearchCharacters
            )
        }
        let canonical = query.precomposedStringWithCanonicalMapping
        guard
            canonical.unicodeScalars.allSatisfy({ scalar in
                !CharacterSet.controlCharacters.contains(scalar)
                    || CharacterSet.whitespacesAndNewlines.contains(scalar)
            })
        else {
            throw IndexSearchError.invalidControlCharacter
        }
        return canonical.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private func recentNotes(limit: Int) async throws -> [IndexSearchHit] {
        try await databasePool.read { database in
            try fetchHits(
                database,
                sql: """
                    SELECT path, title, preview, parse_status, modified_at
                    FROM notes
                    ORDER BY modified_at DESC, path COLLATE BINARY
                    LIMIT ?
                    """,
                arguments: [limit]
            )
        }
    }

    private func matchingNotes(
        _ pattern: FTS5Pattern,
        limit: Int
    ) async throws -> [IndexSearchHit] {
        try await databasePool.read { database in
            try fetchHits(
                database,
                sql: """
                    SELECT
                        notes.path,
                        notes.title,
                        notes.preview,
                        notes.parse_status,
                        notes.modified_at
                    FROM note_fts
                    JOIN notes ON notes.path = note_fts.path
                    WHERE note_fts MATCH ?
                    ORDER BY
                        bm25(note_fts, 0.0, 10.0, 1.0, 5.0),
                        notes.modified_at DESC,
                        notes.path COLLATE BINARY
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )
        }
    }

    private func matchingCJKNotes(
        _ pattern: FTS5Pattern,
        limit: Int
    ) async throws -> [IndexSearchHit] {
        try await databasePool.read { database in
            try fetchHits(
                database,
                sql: """
                    SELECT
                        notes.path,
                        notes.title,
                        notes.preview,
                        notes.parse_status,
                        notes.modified_at
                    FROM note_cjk_fts
                    JOIN notes ON notes.path = note_cjk_fts.path
                    WHERE note_cjk_fts MATCH ?
                    ORDER BY
                        bm25(note_cjk_fts, 0.0, 10.0, 1.0, 5.0),
                        notes.modified_at DESC,
                        notes.path COLLATE BINARY
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )
        }
    }

    private func cjkPattern(_ query: String) -> FTS5Pattern? {
        let transformed = IndexCJKSearchText.transform(query)
        return IndexCJKSearchText.isSingleHanRun(query)
            ? FTS5Pattern(matchingPhrase: transformed)
            : FTS5Pattern(matchingAllTokensIn: transformed)
    }

    private func fetchHits(
        _ database: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> [IndexSearchHit] {
        try Row.fetchAll(database, sql: sql, arguments: arguments).map { row in
            let rawStatus: String = row["parse_status"]
            guard let parseStatus = IndexedNoteParseStatus(rawValue: rawStatus) else {
                throw IndexLibraryReadError.invalidParseStatus(rawStatus)
            }
            return IndexSearchHit(
                path: try VaultPath(decodedRelativePath: row["path"]),
                title: row["title"],
                preview: row["preview"],
                parseStatus: parseStatus,
                modifiedAt: Date(timeIntervalSince1970: row["modified_at"])
            )
        }
    }
}
