import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsUserState
    @testable import BearObsReviewSession
#else
    @testable import BearObs
#endif

/// REQ-005 T5：`ReviewSessionModel` 的纯逻辑测试，不启动 UI。
@MainActor
final class ReviewFlowTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var today: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
    }

    private var nextDay: Date {
        calendar.date(byAdding: .day, value: 1, to: today)!
    }

    private let vaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    // MARK: - 同一批次复用

    func testSameDaySecondOpenKeepsBatchPathOrder() async throws {
        let (store, _) = try makeStore()
        let candidates = (0..<24).map { candidate("note-\($0).md", tags: ["pool"]) }
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)
        await model.updateRule(try makeRule(), today: today, candidates: candidates)
        let first = try XCTUnwrap(model.batch).orderedPaths

        await model.open(today: today, candidates: candidates)
        let second = try XCTUnwrap(model.batch).orderedPaths
        // 杀进程重开：全新会话、同一 store，同一自然日必须看到同一批。
        let relaunched = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)
        await relaunched.open(today: today, candidates: candidates)

        XCTAssertEqual(first, second)
        XCTAssertEqual(second, try XCTUnwrap(relaunched.batch).orderedPaths)
        XCTAssertEqual(second.count, 8)
    }

    // MARK: - 过零点重抽

    func testNextDayOpenRedraws() async throws {
        let (store, _) = try makeStore()
        let candidates = (0..<24).map { candidate("note-\($0).md", tags: ["pool"]) }
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)
        await model.updateRule(try makeRule(), today: today, candidates: candidates)
        let firstDay = try XCTUnwrap(model.batch)

        await model.open(today: nextDay, candidates: candidates)
        let secondDay = try XCTUnwrap(model.batch)

        XCTAssertEqual(
            secondDay.day,
            ReviewBatch.localDay(from: nextDay, calendar: calendar)
        )
        XCTAssertNotEqual(secondDay.day, firstDay.day)
        XCTAssertLessThanOrEqual(secondDay.orderedPaths.count, 8)
        let candidatePaths = Set(candidates.map(\.path))
        XCTAssertTrue(secondDay.orderedPaths.allSatisfy(candidatePaths.contains))
    }

    // MARK: - 规则修改

    func testUpdateRuleProducesBatchUnderNewRule() async throws {
        let (store, _) = try makeStore()
        let candidates = (0..<24).map { candidate("note-\($0).md", tags: $0.isMultiple(of: 2) ? ["even"] : ["odd"]) }
        let firstRule = try makeRule(dailyCount: 8)
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)
        await model.updateRule(firstRule, today: today, candidates: candidates)
        XCTAssertEqual(model.rule, firstRule)

        let secondRule = try makeRule(contentScope: .includingTag("even"), dailyCount: 4)
        await model.updateRule(secondRule, today: today, candidates: candidates)

        XCTAssertEqual(model.rule, secondRule)
        let batch = try XCTUnwrap(model.batch)
        XCTAssertEqual(batch.rule, secondRule)
        XCTAssertEqual(batch.orderedPaths.count, 4)
        XCTAssertEqual(
            batch.day,
            ReviewBatch.localDay(from: today, calendar: calendar)
        )
        let tagsByPath = Dictionary(
            candidates.map { ($0.path, $0.tags) },
            uniquingKeysWith: { first, _ in first }
        )
        XCTAssertTrue(batch.orderedPaths.allSatisfy {
            tagsByPath[$0]?.contains("even") ?? false
        })
        let persisted = try await store.load(vaultID: vaultID)
        XCTAssertEqual(persisted.rule, secondRule)
        XCTAssertEqual(persisted.batch, batch)
    }

    // MARK: - 落盘失败

    func testStoreFailureKeepsResultAndMarksPersistenceFailed() async throws {
        let (store, metadata) = try makeStore()
        let candidates = (0..<12).map { candidate("note-\($0).md") }
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)
        await model.updateRule(try makeRule(), today: today, candidates: candidates)
        XCTAssertFalse(model.persistenceFailed)

        // 沙箱目录不可用：所有落盘请求都抛错。
        try FileManager.default.removeItem(at: metadata)
        let newRule = try makeRule(dailyCount: 12)
        await model.updateRule(newRule, today: today, candidates: candidates)

        XCTAssertTrue(model.persistenceFailed)
        let batch = try XCTUnwrap(model.batch)
        XCTAssertEqual(batch.rule, newRule)
        XCTAssertEqual(batch.orderedPaths.count, 12)
        XCTAssertFalse(batch.orderedPaths.isEmpty)
    }

    // MARK: - 候选为空

    func testEmptyCandidatesYieldEmptyBatchPaths() async throws {
        let (store, _) = try makeStore()
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)

        await model.updateRule(try makeRule(), today: today, candidates: [])

        XCTAssertEqual(model.batch?.orderedPaths, [])
        XCTAssertFalse(model.persistenceFailed)
        let persisted = try await store.load(vaultID: vaultID)
        XCTAssertEqual(persisted.batch?.orderedPaths, [])
    }

    // MARK: - 未设置规则

    func testOpenWithoutRuleDoesNotDraw() async throws {
        let (store, _) = try makeStore()
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)

        await model.open(today: today, candidates: [candidate("a.md")])

        XCTAssertNil(model.rule)
        XCTAssertNil(model.batch)
        XCTAssertFalse(model.persistenceFailed)
    }

    // MARK: - 损坏状态重建（FR-005.2）

    func testCorruptStateFileIsRebuiltOnNextRuleConfirm() async throws {
        let (store, metadata) = try makeStore()
        try Data(#"{"rule":{"contentScope":"all""#.utf8)
            .write(to: stateFile(in: metadata))
        let candidates = (0..<24).map { candidate("note-\($0).md") }
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)
        let rule = try makeRule()

        await model.updateRule(rule, today: today, candidates: candidates)

        // 重新设置规则必须能恢复持久化，不能反复读同一损坏文件。
        XCTAssertFalse(model.persistenceFailed)
        let persisted = try await store.load(vaultID: vaultID)
        XCTAssertEqual(persisted.rule, rule)
        XCTAssertEqual(persisted.batch?.orderedPaths.count, 8)
    }

    func testOversizedStateFileIsRebuiltOnNextRuleConfirm() async throws {
        let (store, metadata) = try makeStore()
        var oversized = Data(#"{"batch":null,"rule":null}"#.utf8)
        oversized.append(
            Data(repeating: 0x20, count: 1_048_576 + 1 - oversized.count)
        )
        try oversized.write(to: stateFile(in: metadata))
        let candidates = (0..<24).map { candidate("note-\($0).md") }
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)

        await model.updateRule(try makeRule(), today: today, candidates: candidates)

        XCTAssertFalse(model.persistenceFailed)
        XCTAssertEqual(model.batch?.orderedPaths.count, 8)
    }

    func testOpenDiscardsUnreadableStateFileSoPersistenceCanRecover() async throws {
        let (store, metadata) = try makeStore()
        try Data(#"{"rule":{"contentScope":"all""#.utf8)
            .write(to: stateFile(in: metadata))
        let model = ReviewSessionModel(store: store, vaultID: vaultID, calendar: calendar)

        await model.open(today: today, candidates: [candidate("a.md")])

        // 损坏文件在进入时删除：读取回到空状态，之后的规则确认可以直接落盘。
        XCTAssertNil(model.rule)
        let persisted = try await store.load(vaultID: vaultID)
        XCTAssertNil(persisted.rule)
        XCTAssertNil(persisted.batch)
    }
}

extension ReviewFlowTests {
    private func makeStore() throws -> (ReviewStateStore, URL) {
        let metadata = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: metadata,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: metadata)
        }
        return (try ReviewStateStore(metadataDirectory: metadata), metadata)
    }

    private func stateFile(in metadataDirectory: URL) -> URL {
        metadataDirectory.appendingPathComponent("review-state.json")
    }

    private func makeRule(
        contentScope: ReviewRule.ContentScope = .all,
        timeScope: ReviewRule.TimeScope = .all,
        dailyCount: Int = ReviewRule.defaultDailyCount
    ) throws -> ReviewRule {
        try ReviewRule(
            contentScope: contentScope,
            timeScope: timeScope,
            dailyCount: dailyCount
        )
    }

    private func candidate(
        _ path: String,
        tags: Set<String> = [],
        isReadable: Bool = true
    ) -> ReviewCandidate {
        ReviewCandidate(
            path: path,
            modifiedAt: today,
            tags: tags,
            isReadable: isReadable
        )
    }
}
