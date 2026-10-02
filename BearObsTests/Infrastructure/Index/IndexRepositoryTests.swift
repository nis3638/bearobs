import Foundation
import GRDB
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
    @testable import BearObsIndex
#else
    @testable import BearObs
#endif

final class IndexRepositoryTests: XCTestCase {
    func testInputRejectsMetadataThatDoesNotDescribeTheParsedBytes() throws {
        let data = Data("body".utf8)
        let path = try VaultPath(decodedRelativePath: "note.md")
        let parsedNote = try MarkdownNoteParser.parse(data, at: path)
        let hash = try ContentHash(hex: String(repeating: "a", count: 64))

        XCTAssertThrowsError(
            try IndexNoteInput(
                path: path,
                parsedNote: parsedNote,
                contentHash: hash,
                modifiedAt: Date(timeIntervalSince1970: 0),
                byteSize: 5
            )
        ) { error in
            XCTAssertEqual(
                error as? IndexNoteInputError,
                .byteSizeMismatch(expected: 4, actual: 5)
            )
        }
        XCTAssertThrowsError(
            try IndexNoteInput(
                path: path,
                parsedNote: parsedNote,
                contentHash: hash,
                modifiedAt: Date(timeIntervalSince1970: .infinity),
                byteSize: 4
            )
        ) { error in
            XCTAssertEqual(error as? IndexNoteInputError, .invalidModifiedAt)
        }
    }

    func testReplaceStoresOneParsedNoteAndAllDerivedOccurrences() async throws {
        let repository = try makeRepository()
        let source = """
            ---
            title: Indexed Note
            tags: [Swift, 中文]
            ---
            # Body Heading

            Searchable body marker with #inline.

            [[Target|Alias]] then [[Target]].
            ![[Assets/image.png]]
            """
        let input = try makeInput(source, path: "Folder/Note.md", hashDigit: "a")

        try await repository.replace(input)

        let note = try await repository.databasePool.read { database in
            let row = try Row.fetchOne(
                database, sql: "SELECT * FROM notes WHERE path = ?",
                arguments: [
                    input.path.description
                ])
            return (
                title: row?["title"] as String?,
                contentHash: row?["content_hash"] as String?,
                byteSize: row?["byte_size"] as Int64?,
                parseStatus: row?["parse_status"] as String?
            )
        }
        XCTAssertEqual(note.title, "Indexed Note")
        XCTAssertEqual(note.contentHash, input.contentHash.hex)
        XCTAssertEqual(note.byteSize, Int64(source.utf8.count))
        XCTAssertEqual(note.parseStatus, "complete")

        let tags = try await repository.databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT tag_name, display_name
                    FROM note_tags
                    WHERE note_path = ?
                    ORDER BY tag_name COLLATE BINARY
                    """,
                arguments: [input.path.description]
            ).map { ($0["tag_name"] as String, $0["display_name"] as String) }
        }
        XCTAssertEqual(tags.map { $0.0 }, ["inline", "swift", "中文"])
        XCTAssertEqual(tags.map { $0.1 }, ["inline", "Swift", "中文"])

        let links = try await repository.databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT raw_target, alias, resolution_state, source_start, source_end
                    FROM links
                    WHERE source_path = ?
                    ORDER BY source_start
                    """,
                arguments: [input.path.description]
            ).map {
                (
                    rawTarget: $0["raw_target"] as String,
                    alias: $0["alias"] as String?,
                    resolutionState: $0["resolution_state"] as String,
                    sourceStart: $0["source_start"] as Int64,
                    sourceEnd: $0["source_end"] as Int64
                )
            }
        }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links.map(\.rawTarget), ["Target", "Target"])
        XCTAssertEqual(links[0].alias, "Alias")
        XCTAssertNil(links[1].alias)
        XCTAssertTrue(links.allSatisfy { $0.resolutionState == "unresolved" })
        XCTAssertTrue(links.allSatisfy { $0.sourceEnd > $0.sourceStart })

        let attachment = try await repository.databasePool.read { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM attachments WHERE note_path = ?",
                arguments: [input.path.description]
            )
            return (
                rawTarget: row?["raw_target"] as String?,
                cacheState: row?["cache_state"] as String?
            )
        }
        XCTAssertEqual(attachment.rawTarget, "Assets/image.png")
        XCTAssertEqual(attachment.cacheState, "not_cached")

        let matching = try await matchingPaths("searchable AND inline", in: repository)
        XCTAssertEqual(
            matching,
            [
                input.path.description
            ])
    }

    func testReplaceStoresRecoverableParserDiagnostics() async throws {
        let repository = try makeRepository()
        let input = try makeInput(
            "---\ntitle: [\n---\nreadable body",
            path: "degraded.md",
            hashDigit: "d"
        )

        try await repository.replace(input)

        let result = try await repository.databasePool.read { database in
            (
                status: try String.fetchOne(
                    database,
                    sql: "SELECT parse_status FROM notes WHERE path = 'degraded.md'"
                ),
                diagnostics: try String.fetchAll(
                    database,
                    sql: "SELECT code FROM note_diagnostics WHERE note_path = 'degraded.md'"
                )
            )
        }
        XCTAssertEqual(result.status, "degraded")
        XCTAssertEqual(result.diagnostics, ["frontmatter.invalid-yaml"])
    }

    func testReplaceRemovesStaleRowsAndRecomputesTagDisplayName() async throws {
        let repository = try makeRepository()
        let first = try makeInput(
            "---\ntags: [Zeta, OldOnly]\n---\noldterm [[Old]]",
            path: "first.md",
            hashDigit: "a"
        )
        let second = try makeInput(
            "---\ntags: [zeta]\n---\nsecond body",
            path: "second.md",
            hashDigit: "b"
        )
        try await repository.replace(first)
        try await repository.replace(second)

        let replacement = try makeInput(
            "---\ntags: [NewOnly]\n---\nnewterm [[New]]",
            path: "first.md",
            hashDigit: "c"
        )
        try await repository.replace(replacement)

        let snapshot = try await repository.databasePool.read { database in
            (
                tags: try Row.fetchAll(
                    database,
                    sql: "SELECT normalized_name, display_name FROM tags ORDER BY normalized_name"
                ).map {
                    (
                        normalizedName: $0["normalized_name"] as String,
                        displayName: $0["display_name"] as String
                    )
                },
                links: try String.fetchAll(
                    database,
                    sql: "SELECT raw_target FROM links ORDER BY raw_target"
                )
            )
        }
        XCTAssertEqual(snapshot.tags.map(\.normalizedName), ["newonly", "zeta"])
        XCTAssertEqual(snapshot.tags.map(\.displayName), ["NewOnly", "zeta"])
        XCTAssertEqual(snapshot.links, ["New"])
        let oldMatches = try await matchingPaths("oldterm", in: repository)
        let newMatches = try await matchingPaths("newterm", in: repository)
        XCTAssertEqual(oldMatches, [])
        XCTAssertEqual(newMatches, ["first.md"])
    }

    func testReplaceRollsBackEveryTableWhenOneOccurrenceFails() async throws {
        let repository = try makeRepository()
        let original = try makeInput(
            "---\ntitle: Original\ntags: [Old]\n---\noldterm [[Safe]]",
            path: "rollback.md",
            hashDigit: "a"
        )
        try await repository.replace(original)
        try await repository.databasePool.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_link
                    BEFORE INSERT ON links
                    WHEN NEW.raw_target = 'Reject'
                    BEGIN
                        SELECT RAISE(ABORT, 'injected failure');
                    END
                    """
            )
        }
        let rejected = try makeInput(
            "---\ntitle: Rejected\ntags: [New]\n---\nnewterm [[Reject]]",
            path: "rollback.md",
            hashDigit: "b"
        )

        do {
            try await repository.replace(rejected)
            XCTFail("Expected the injected SQLite failure.")
        } catch {
            XCTAssertTrue(error is DatabaseError)
        }

        let state = try await repository.databasePool.read { database in
            (
                title: try String.fetchOne(
                    database,
                    sql: "SELECT title FROM notes WHERE path = 'rollback.md'"
                ),
                tags: try String.fetchAll(
                    database,
                    sql: "SELECT tag_name FROM note_tags WHERE note_path = 'rollback.md'"
                ),
                links: try String.fetchAll(
                    database,
                    sql: "SELECT raw_target FROM links WHERE source_path = 'rollback.md'"
                )
            )
        }
        XCTAssertEqual(state.title, "Original")
        XCTAssertEqual(state.tags, ["old"])
        XCTAssertEqual(state.links, ["Safe"])
        let oldMatches = try await matchingPaths("oldterm", in: repository)
        let newMatches = try await matchingPaths("newterm", in: repository)
        XCTAssertEqual(oldMatches, ["rollback.md"])
        XCTAssertEqual(newMatches, [])
    }

    func testRemoveDeletesTheNoteFTSAndOrphanTags() async throws {
        let repository = try makeRepository()
        let input = try makeInput(
            "---\ntags: [Disposable]\n---\nremoveme [[Target]] ![[image.png]]",
            path: "remove.md",
            hashDigit: "d"
        )
        try await repository.replace(input)

        try await repository.remove(input.path)

        let counts = try await repository.databasePool.read { database in
            try ["notes", "tags", "note_tags", "links", "attachments", "note_fts"].map {
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \($0)") ?? -1
            }
        }
        XCTAssertEqual(counts, [0, 0, 0, 0, 0, 0])
    }

    func testAvailabilityPersistsOnlyIndexedStalePathsAndAnAnonymousTotal() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("index.sqlite")
        let repository = try SQLiteIndexRepository(path: databaseURL.path)
        let indexed = try makeInput("# Indexed", path: "indexed.md", hashDigit: "a")
        let unindexedPath = try VaultPath(decodedRelativePath: "private/new.md")
        try await repository.replace(indexed)

        try await repository.updateAvailability(
            unavailablePaths: [indexed.path, unindexedPath],
            readablePaths: [],
            inventoryComplete: true
        )

        let reopened = try SQLiteIndexRepository(path: databaseURL.path)
        let state = try await reopened.availabilityState()
        let persistedDiagnostics = try await reopened.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT code FROM note_diagnostics WHERE note_path = 'indexed.md'"
            )
        }
        XCTAssertEqual(
            state,
            IndexAvailabilityState(
                unavailableCount: 2,
                staleNotePaths: [indexed.path]
            )
        )
        XCTAssertEqual(state.diagnostic, .sourceTemporarilyUnavailable)
        XCTAssertEqual(persistedDiagnostics, ["index.source-temporarily-unavailable"])
    }

    func testAvailabilityRecoveryClearsOnlyTheStaleDiagnostic() async throws {
        let repository = try makeRepository()
        let degraded = try makeInput(
            "---\ntitle: [\n---\nreadable body",
            path: "degraded.md",
            hashDigit: "d"
        )
        try await repository.replace(degraded)
        try await repository.updateAvailability(
            unavailablePaths: [degraded.path],
            readablePaths: [],
            inventoryComplete: true
        )

        try await repository.updateAvailability(
            unavailablePaths: [],
            readablePaths: [degraded.path],
            inventoryComplete: true
        )

        let state = try await repository.availabilityState()
        let diagnostics = try await repository.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT code FROM note_diagnostics WHERE note_path = 'degraded.md'"
            )
        }
        XCTAssertEqual(state, .init(unavailableCount: 0, staleNotePaths: []))
        XCTAssertNil(state.diagnostic)
        XCTAssertEqual(diagnostics, ["frontmatter.invalid-yaml"])
    }

    private func makeInput(
        _ source: String,
        path: String,
        hashDigit: Character
    ) throws -> IndexNoteInput {
        let data = Data(source.utf8)
        let vaultPath = try VaultPath(decodedRelativePath: path)
        return try IndexNoteInput(
            path: vaultPath,
            parsedNote: try MarkdownNoteParser.parse(data, at: vaultPath),
            contentHash: try ContentHash(hex: String(repeating: hashDigit, count: 64)),
            modifiedAt: Date(timeIntervalSince1970: 1_234.5),
            byteSize: Int64(data.count)
        )
    }

    private func makeRepository() throws -> SQLiteIndexRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
    }

    private func matchingPaths(
        _ query: String,
        in repository: SQLiteIndexRepository
    ) async throws -> [String] {
        try await repository.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT path FROM note_fts WHERE note_fts MATCH ? ORDER BY path",
                arguments: [query]
            )
        }
    }
}
