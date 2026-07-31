import Foundation
import GRDB
import XCTest

@testable import GRDBFTS5Spike

final class GRDBFTS5SpikeTests: XCTestCase {
    func testMigrationUpgradesExistingRowsAndRemainsIdempotent() async throws {
        let databaseURL = try makeDatabaseURL()
        let queue = try DatabaseQueue(path: databaseURL.path)
        let migrator = GRDBFTS5Schema.makeMigrator()

        try migrator.migrate(queue, upTo: "v1_create_spike_documents")
        try await queue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO spike_documents (path, title, body)
                    VALUES (?, ?, ?)
                    """,
                arguments: ["legacy.md", "Legacy SQLite", "Migration backfill marker"]
            )
        }

        let firstOpen = try GRDBFTS5Spike(path: databaseURL.path)
        let migratedHits = try await firstOpen.search("backfill")
        let firstOpenMigrations = try await firstOpen.appliedMigrationIdentifiers()
        XCTAssertEqual(migratedHits.map(\.path), ["legacy.md"])
        XCTAssertEqual(
            firstOpenMigrations,
            ["v1_create_spike_documents", "v2_create_spike_fts"]
        )

        let secondOpen = try GRDBFTS5Spike(path: databaseURL.path)
        let secondOpenCount = try await secondOpen.documentCount()
        let secondOpenMigrations = try await secondOpen.appliedMigrationIdentifiers()
        XCTAssertEqual(secondOpenCount, 1)
        XCTAssertEqual(
            secondOpenMigrations,
            ["v1_create_spike_documents", "v2_create_spike_fts"]
        )
    }

    func testAsyncWritesAndConcurrentReadsPreserveAllDocuments() async throws {
        let spike = try GRDBFTS5Spike(path: makeDatabaseURL().path)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for batchIndex in 0..<20 {
                group.addTask {
                    let documents = (0..<50).map { documentIndex in
                        let identifier = batchIndex * 50 + documentIndex
                        return GRDBFTS5Spike.Document(
                            path: "async/\(identifier).md",
                            title: "Async \(identifier)",
                            body: "concurrency marker \(identifier)"
                        )
                    }
                    try await spike.upsert(documents)
                }
            }

            for _ in 0..<10 {
                group.addTask {
                    _ = try await spike.documentCount()
                }
            }

            try await group.waitForAll()
        }

        let count = try await spike.documentCount()
        let searchCount = try await spike.search("concurrency", limit: 1_100).count
        XCTAssertEqual(count, 1_000)
        XCTAssertEqual(searchCount, 1_000)
    }

    func testUnicode61SearchIsCaseAndDiacriticInsensitive() async throws {
        let spike = try GRDBFTS5Spike(path: makeDatabaseURL().path)
        try await spike.upsert([
            .init(
                path: "cafe.md",
                title: "Café Database",
                body: "SQLite full text search"
            ),
            .init(
                path: "other.md",
                title: "Unrelated",
                body: "No matching token"
            ),
        ])

        let cafeHits = try await spike.search("CAFE")
        let sqliteHits = try await spike.search("sqlite search")
        let blankHits = try await spike.search("   ")
        XCTAssertEqual(cafeHits.map(\.path), ["cafe.md"])
        XCTAssertEqual(sqliteHits.map(\.path), ["cafe.md"])
        XCTAssertEqual(blankHits, [])
    }

    func testUpsertReplacesTheFTSRowInTheSameTransaction() async throws {
        let spike = try GRDBFTS5Spike(path: makeDatabaseURL().path)
        try await spike.upsert([
            .init(path: "replace.md", title: "Original", body: "oldterm")
        ])
        try await spike.upsert([
            .init(path: "replace.md", title: "Updated", body: "newterm")
        ])

        let oldHits = try await spike.search("oldterm")
        let newHits = try await spike.search("newterm")
        let count = try await spike.documentCount()
        XCTAssertEqual(oldHits, [])
        XCTAssertEqual(newHits.map(\.path), ["replace.md"])
        XCTAssertEqual(count, 1)
    }

    func testBatchFailureRollsBackDocumentAndFTSChanges() async throws {
        let databaseURL = try makeDatabaseURL()
        let spike = try GRDBFTS5Spike(path: databaseURL.path)
        try await spike.upsert([
            .init(path: "existing.md", title: "Original", body: "oldterm")
        ])
        let failureInjector = try DatabaseQueue(path: databaseURL.path)
        try await failureInjector.write { database in
            try database.execute(
                sql: """
                    CREATE TRIGGER reject_spike_document
                    BEFORE INSERT ON spike_documents
                    WHEN NEW.path = 'reject.md'
                    BEGIN
                        SELECT RAISE(ABORT, 'injected failure');
                    END
                    """
            )
        }

        do {
            try await spike.upsert([
                .init(path: "existing.md", title: "Updated", body: "newterm"),
                .init(path: "reject.md", title: "Rejected", body: "rejectedterm"),
            ])
            XCTFail("Expected the injected SQLite failure.")
        } catch {
            XCTAssertTrue(error is DatabaseError)
        }

        let oldHits = try await spike.search("oldterm")
        let newHits = try await spike.search("newterm")
        let rejectedHits = try await spike.search("rejectedterm")
        let count = try await spike.documentCount()
        XCTAssertEqual(oldHits.map(\.path), ["existing.md"])
        XCTAssertEqual(newHits, [])
        XCTAssertEqual(rejectedHits, [])
        XCTAssertEqual(count, 1)
    }

    func testUnicode61FindsAContiguousChinesePhrase() async throws {
        let spike = try GRDBFTS5Spike(path: makeDatabaseURL().path)
        try await spike.upsert([
            .init(path: "中文.md", title: "离线笔记搜索", body: "完整连续词组")
        ])

        let hits = try await spike.search("离线笔记搜索")
        XCTAssertEqual(hits.map(\.path), ["中文.md"])
    }

    func testTenThousandDocumentBaseline() async throws {
        let spike = try GRDBFTS5Spike(path: makeDatabaseURL().path)
        let documents = (0..<10_000).map { index in
            GRDBFTS5Spike.Document(
                path: "notes/\(index).md",
                title: "Note \(index)",
                body: "common baseline token unique\(index)"
            )
        }
        let clock = ContinuousClock()

        let insertionStart = clock.now
        try await spike.upsert(documents)
        let insertionDuration = insertionStart.duration(to: clock.now)

        _ = try await spike.search("unique9999")
        var searchDurations: [ContinuousClock.Duration] = []
        var hits: [GRDBFTS5Spike.SearchHit] = []
        for _ in 0..<30 {
            let searchStart = clock.now
            hits = try await spike.search("unique9999")
            searchDurations.append(searchStart.duration(to: clock.now))
        }
        let p95SearchDuration = searchDurations.sorted()[28]

        let count = try await spike.documentCount()
        XCTAssertEqual(count, 10_000)
        XCTAssertEqual(hits.map(\.path), ["notes/9999.md"])
        print(
            "M0-07 10k macOS baseline: insert=\(insertionDuration), "
                + "search_p95=\(p95SearchDuration), samples=30"
        )
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
        return directory.appendingPathComponent("index-spike.sqlite")
    }
}
