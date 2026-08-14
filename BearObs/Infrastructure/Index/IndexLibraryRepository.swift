import Foundation
import GRDB

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public enum IndexedNoteParseStatus: String, Equatable, Sendable {
    case complete
    case degraded
    case failed
}

public struct IndexedNoteSummary: Equatable, Identifiable, Sendable {
    public var id: VaultPath { path }

    public let path: VaultPath
    public let title: String
    public let preview: String
    public let modifiedAt: Date
    public let parseStatus: IndexedNoteParseStatus

    public init(
        path: VaultPath,
        title: String,
        preview: String,
        modifiedAt: Date,
        parseStatus: IndexedNoteParseStatus
    ) {
        self.path = path
        self.title = title
        self.preview = preview
        self.modifiedAt = modifiedAt
        self.parseStatus = parseStatus
    }
}

public enum IndexLibraryReadError: Error, Equatable, Sendable {
    case invalidParseStatus(String)
}

extension SQLiteIndexRepository {
    public func libraryNotes() async throws -> [IndexedNoteSummary] {
        try Task.checkCancellation()
        let notes = try await databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT path, title, preview, modified_at, parse_status
                    FROM notes
                    ORDER BY modified_at DESC, path COLLATE BINARY
                    """
            ).map(Self.decodeNoteSummary)
        }
        try Task.checkCancellation()
        return notes
    }
}
