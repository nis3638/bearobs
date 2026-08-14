import Foundation
import GRDB
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsIndex
#else
    @testable import BearObs
#endif

final class ChineseSearchQualityTests: XCTestCase {
    func testChineseSearchCorpusImprovesSubstringRecallOverPlainUnicode61() async throws {
        let repository = try makeRepository()
        let scanner = try IncrementalIndexScanner(
            root: try corpusRoot(),
            repository: repository
        )
        let report = try await scanner.rebuild()
        let expectations: [(query: String, paths: [String])] = [
            ("离线", ["离线优先.md"]),
            ("全文", ["全文检索.md"]),
            ("缓存", ["离线优先.md"]),
            ("冲突", ["同步冲突.md"]),
            ("研发", ["研发计划.md"]),
            ("iOS 研发", ["研发计划.md"]),
            ("离线全文", []),
            ("同步搜索", []),
        ]

        var unicode61Hits = 0
        var improvedHits = 0
        for expectation in expectations {
            if try await baselinePaths(expectation.query, repository: repository).sorted()
                == expectation.paths
            {
                unicode61Hits += 1
            }
            if try await repository.search(expectation.query).map(\.path.description).sorted()
                == expectation.paths
            {
                improvedHits += 1
            }
        }

        XCTAssertEqual(report.indexed, 5)
        XCTAssertEqual(unicode61Hits, 4, "Measurement baseline changed; review the strategy")
        XCTAssertEqual(improvedHits, expectations.count)
    }

    func testTenThousandChineseDocumentsMeetLatencyAndIndexVolumeBudgets() async throws {
        let repository = try makeRepository()
        try await seedChineseDocuments(10_000, repository: repository)

        let clock = ContinuousClock()
        var durations: [Duration] = []
        for _ in 0..<30 {
            let start = clock.now
            let hits = try await repository.search("编号 9999")
            durations.append(start.duration(to: clock.now))
            XCTAssertEqual(hits.map(\.path.description), ["notes/9999.md"])
        }
        let p95 = durations.sorted()[28]
        let sizes = try await ftsPageSizes(repository)

        XCTAssertLessThan(p95, .milliseconds(300))
        XCTAssertGreaterThan(sizes.cjk, sizes.unicode61)
        XCTAssertLessThanOrEqual(sizes.cjk, sizes.unicode61 * 8)
        print(
            "CHINESE_FTS_MEASUREMENT documents=10000 p95_ms=\(milliseconds(p95)) "
                + "unicode61_bytes=\(sizes.unicode61) cjk_bytes=\(sizes.cjk)"
        )
    }

    func testCJKSearchTransformationPreservesSubstringAdjacency() {
        XCTAssertEqual(
            IndexCJKSearchText.transform("离线笔记"),
            "离 离线 线 线笔 笔 笔记 记"
        )
        XCTAssertEqual(IndexCJKSearchText.transform("iOS 搜索"), "iOS 搜 搜索 索")
    }
}

extension ChineseSearchQualityTests {
    private func makeRepository() throws -> SQLiteIndexRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
    }

    private func corpusRoot() throws -> URL {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle(for: Self.self)
        #endif
        return try XCTUnwrap(
            bundle.url(forResource: "ChineseSearchVault", withExtension: nil)
        ).appendingPathComponent("vault", isDirectory: true)
    }

    private func baselinePaths(
        _ query: String,
        repository: SQLiteIndexRepository
    ) async throws -> [String] {
        guard let pattern = FTS5Pattern(matchingAllTokensIn: query) else { return [] }
        return try await repository.databasePool.read { database in
            try String.fetchAll(
                database,
                sql: "SELECT path FROM note_fts WHERE note_fts MATCH ?",
                arguments: [pattern]
            )
        }
    }

    private func seedChineseDocuments(
        _ count: Int,
        repository: SQLiteIndexRepository
    ) async throws {
        try await repository.databasePool.write { database in
            let insertNote = try database.makeStatement(
                sql: """
                    INSERT INTO notes (
                        path, title, preview, content_hash, modified_at, byte_size,
                        parse_status
                    ) VALUES (?, ?, '', ?, ?, ?, 'complete')
                    """
            )
            let insertFTS = try database.makeStatement(
                sql: "INSERT INTO note_fts (path, title, body, tags) VALUES (?, ?, ?, '')"
            )
            let insertCJK = try database.makeStatement(
                sql: "INSERT INTO note_cjk_fts (path, title, body, tags) VALUES (?, ?, ?, '')"
            )
            for index in 0..<count {
                let path = "notes/\(index).md"
                let title = "离线笔记编号 \(index)"
                let body = "本地缓存、全文搜索与同步冲突处理。"
                try insertNote.execute(
                    arguments: [
                        path, title, String(repeating: "a", count: 64),
                        Double(index), Int64(body.utf8.count),
                    ]
                )
                try insertFTS.execute(arguments: [path, title, body])
                try insertCJK.execute(
                    arguments: [
                        path, IndexCJKSearchText.transform(title),
                        IndexCJKSearchText.transform(body),
                    ]
                )
            }
        }
    }

    private func ftsPageSizes(
        _ repository: SQLiteIndexRepository
    ) async throws -> (unicode61: Int64, cjk: Int64) {
        try await repository.databasePool.read { database in
            let unicode61 = try Int64.fetchOne(
                database,
                sql: "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name GLOB 'note_fts*'"
            )!
            let cjk = try Int64.fetchOne(
                database,
                sql: "SELECT COALESCE(SUM(pgsize), 0) FROM dbstat WHERE name GLOB 'note_cjk_fts*'"
            )!
            return (unicode61, cjk)
        }
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
