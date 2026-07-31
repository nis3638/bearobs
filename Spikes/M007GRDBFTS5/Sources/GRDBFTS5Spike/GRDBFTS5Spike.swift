import GRDB

public struct GRDBFTS5Spike: Sendable {
    public struct Document: Equatable, Sendable {
        public let path: String
        public let title: String
        public let body: String

        public init(path: String, title: String, body: String) {
            self.path = path
            self.title = title
            self.body = body
        }
    }

    public struct SearchHit: Equatable, Sendable {
        public let path: String
        public let title: String
    }

    private let databasePool: DatabasePool

    public init(path: String) throws {
        let databasePool = try DatabasePool(path: path)
        try GRDBFTS5Schema.makeMigrator().migrate(databasePool)
        self.databasePool = databasePool
    }

    public func appliedMigrationIdentifiers() async throws -> [String] {
        try await databasePool.read { database in
            try GRDBFTS5Schema.makeMigrator().appliedMigrations(database)
        }
    }

    public func upsert(_ documents: [Document]) async throws {
        guard !documents.isEmpty else {
            return
        }

        try await databasePool.write { database in
            let upsertDocument = try database.makeStatement(
                sql: """
                    INSERT INTO spike_documents (path, title, body)
                    VALUES (?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        title = excluded.title,
                        body = excluded.body
                    """
            )
            let deleteSearchRow = try database.makeStatement(
                sql: "DELETE FROM spike_document_fts WHERE path = ?"
            )
            let insertSearchRow = try database.makeStatement(
                sql: """
                    INSERT INTO spike_document_fts (path, title, body)
                    VALUES (?, ?, ?)
                    """
            )

            for document in documents {
                let arguments: StatementArguments = [
                    document.path,
                    document.title,
                    document.body,
                ]
                try upsertDocument.execute(arguments: arguments)
                try deleteSearchRow.execute(arguments: [document.path])
                try insertSearchRow.execute(arguments: arguments)
            }
        }
    }

    public func documentCount() async throws -> Int {
        try await databasePool.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM spike_documents") ?? 0
        }
    }

    public func search(_ query: String, limit: Int = 20) async throws -> [SearchHit] {
        guard limit > 0, let pattern = FTS5Pattern(matchingAllTokensIn: query) else {
            return []
        }

        return try await databasePool.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT path, title
                    FROM spike_document_fts
                    WHERE spike_document_fts MATCH ?
                    ORDER BY bm25(spike_document_fts), path COLLATE BINARY
                    LIMIT ?
                    """,
                arguments: [pattern, limit]
            )
            return rows.map { row in
                SearchHit(path: row["path"], title: row["title"])
            }
        }
    }
}

enum GRDBFTS5Schema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_create_spike_documents") { database in
            try database.create(table: "spike_documents") { table in
                table.column("path", .text).primaryKey()
                table.column("title", .text).notNull()
                table.column("body", .text).notNull()
            }
        }

        migrator.registerMigration("v2_create_spike_fts") { database in
            try database.create(
                virtualTable: "spike_document_fts",
                using: FTS5()
            ) { table in
                table.tokenizer = .unicode61()
                table.column("path").notIndexed()
                table.column("title")
                table.column("body")
            }
            try database.execute(
                sql: """
                    INSERT INTO spike_document_fts (path, title, body)
                    SELECT path, title, body
                    FROM spike_documents
                    """
            )
        }

        return migrator
    }
}
