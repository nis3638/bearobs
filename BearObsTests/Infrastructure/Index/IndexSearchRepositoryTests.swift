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

final class IndexSearchRepositoryTests: XCTestCase {
    func testRanksTitleThenTagThenBodyAndReturnsStoredPreview() async throws {
        let repository = try makeRepository()
        try await insert(
            "# Needle\n\nTitle preview.",
            at: "title.md",
            modifiedAt: Date(timeIntervalSince1970: 1),
            in: repository
        )
        try await insert(
            "# Tag note\n\nTag preview. #needle",
            at: "tag.md",
            modifiedAt: Date(timeIntervalSince1970: 2),
            in: repository
        )
        try await insert(
            "# Body note\n\nNeedle appears only in the body.",
            at: "body.md",
            modifiedAt: Date(timeIntervalSince1970: 3),
            in: repository
        )

        let hits = try await repository.search("needle")

        XCTAssertEqual(hits.map(\.path.description), ["title.md", "tag.md", "body.md"])
        XCTAssertEqual(hits.first?.preview, "Title preview.")
        XCTAssertEqual(hits.first?.parseStatus, .complete)
    }

    func testBlankQueryReturnsMostRecentlyModifiedNotes() async throws {
        let repository = try makeRepository()
        try await insert(
            "old",
            at: "old.md",
            modifiedAt: Date(timeIntervalSince1970: 10),
            in: repository
        )
        try await insert(
            "new",
            at: "new.md",
            modifiedAt: Date(timeIntervalSince1970: 20),
            in: repository
        )

        let hits = try await repository.search(" \n\t ")

        XCTAssertEqual(hits.map(\.path.description), ["new.md", "old.md"])
    }

    func testBlankQueryReturnsAtMostTwentyNotesByDefault() async throws {
        let repository = try makeRepository()
        for index in 0..<25 {
            try await insert(
                "note \(index)",
                at: String(format: "note-%02d.md", index),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                in: repository
            )
        }

        let hits = try await repository.search(" \n\t ")

        XCTAssertEqual(hits.count, 20)
        XCTAssertEqual(
            hits.map(\.path.description),
            (5..<25).reversed().map { String(format: "note-%02d.md", $0) }
        )
    }

    func testBlankQueryBreaksModifiedAtTiesByBinaryPathOrder() async throws {
        let repository = try makeRepository()
        let modifiedAt = Date(timeIntervalSince1970: 10)
        for path in ["z.md", "a.md", "Z.md", "A.md"] {
            try await insert(
                path,
                at: path,
                modifiedAt: modifiedAt,
                in: repository
            )
        }

        let hits = try await repository.search("")

        XCTAssertEqual(hits.map(\.path.description), ["A.md", "Z.md", "a.md", "z.md"])
    }

    func testQueryIsUnicodeNormalizedAndFTSSyntaxIsNeverInterpolated() async throws {
        let repository = try makeRepository()
        try await insert(
            "# Café",
            at: "cafe.md",
            modifiedAt: .distantPast,
            in: repository
        )

        let normalized = try await repository.search("  CAFE  ")
        let hostile = try await repository.search("\" OR 1=1 --")
        let count = try await repository.databasePool.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM notes")!
        }

        XCTAssertEqual(normalized.map(\.path.description), ["cafe.md"])
        XCTAssertEqual(hostile, [])
        XCTAssertEqual(count, 1)
    }

    func testRejectsUnboundedOrInvalidQueries() async throws {
        let repository = try makeRepository()

        await assertSearchError(.invalidLimit, repository: repository, query: "ok", limit: 0)
        await assertSearchError(.invalidLimit, repository: repository, query: "ok", limit: 101)
        await assertSearchError(
            .queryTooLong(maximumCharacters: 256),
            repository: repository,
            query: String(repeating: "a", count: 257)
        )
        await assertSearchError(
            .invalidControlCharacter,
            repository: repository,
            query: "bad\0query"
        )
    }
}

extension IndexSearchRepositoryTests {
    private func makeRepository() throws -> SQLiteIndexRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
    }

    private func insert(
        _ source: String,
        at rawPath: String,
        modifiedAt: Date,
        in repository: SQLiteIndexRepository
    ) async throws {
        let path = try VaultPath(decodedRelativePath: rawPath)
        let data = Data(source.utf8)
        let parsed = try MarkdownNoteParser.parse(data, at: path)
        let input = try IndexNoteInput(
            path: path,
            parsedNote: parsed,
            contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
            modifiedAt: modifiedAt,
            byteSize: Int64(data.count)
        )
        try await repository.replace(input)
    }

    private func assertSearchError(
        _ expected: IndexSearchError,
        repository: SQLiteIndexRepository,
        query: String,
        limit: Int = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await repository.search(query, limit: limit)
            XCTFail("Expected search to fail", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? IndexSearchError, expected, file: file, line: line)
        }
    }
}
