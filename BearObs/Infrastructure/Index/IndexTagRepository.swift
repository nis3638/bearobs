import Foundation
import GRDB

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public struct IndexedTagSummary: Equatable, Identifiable, Sendable {
    public var id: String { normalizedName }

    public let normalizedName: String
    public let displayName: String
    public let noteCount: Int

    public init(normalizedName: String, displayName: String, noteCount: Int) {
        self.normalizedName = normalizedName
        self.displayName = displayName
        self.noteCount = noteCount
    }
}

extension SQLiteIndexRepository {
    public func libraryTags() async throws -> [IndexedTagSummary] {
        try Task.checkCancellation()
        let tags = try await databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        tags.normalized_name,
                        tags.display_name,
                        COUNT(note_tags.note_path) AS note_count
                    FROM tags
                    JOIN note_tags ON note_tags.tag_name = tags.normalized_name
                    GROUP BY tags.normalized_name, tags.display_name
                    ORDER BY tags.display_name COLLATE BINARY, tags.normalized_name COLLATE BINARY
                    """
            ).map { row in
                IndexedTagSummary(
                    normalizedName: row["normalized_name"],
                    displayName: row["display_name"],
                    noteCount: row["note_count"]
                )
            }
        }
        try Task.checkCancellation()
        return tags
    }

    public func libraryNotes(taggedWith tag: IndexedTagSummary) async throws
        -> [IndexedNoteSummary]
    {
        try Task.checkCancellation()
        let notes = try await databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        notes.path,
                        notes.title,
                        notes.preview,
                        notes.modified_at,
                        notes.parse_status
                    FROM note_tags
                    JOIN notes ON notes.path = note_tags.note_path
                    WHERE note_tags.tag_name = ?
                    ORDER BY notes.modified_at DESC, notes.path COLLATE BINARY
                    """,
                arguments: [tag.normalizedName]
            ).map(Self.decodeNoteSummary)
        }
        try Task.checkCancellation()
        return notes
    }
}

extension SQLiteIndexRepository {
    static func decodeNoteSummary(_ row: Row) throws -> IndexedNoteSummary {
        let rawStatus: String = row["parse_status"]
        guard let parseStatus = IndexedNoteParseStatus(rawValue: rawStatus) else {
            throw IndexLibraryReadError.invalidParseStatus(rawStatus)
        }
        return IndexedNoteSummary(
            path: try VaultPath(decodedRelativePath: row["path"]),
            title: row["title"],
            preview: row["preview"],
            modifiedAt: Date(timeIntervalSince1970: row["modified_at"]),
            parseStatus: parseStatus
        )
    }
}
