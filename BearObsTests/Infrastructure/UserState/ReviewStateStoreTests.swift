import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsUserState
#else
    @testable import BearObs
#endif

final class ReviewStateStoreTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
    }

    private let vaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let otherVaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    // MARK: - 空状态

    func testMissingStateFileLoadsEmptyStateWithoutCreatingAFile() async throws {
        let metadata = try makeDirectory()
        let store = try ReviewStateStore(metadataDirectory: metadata)

        let state = try await store.load(vaultID: vaultID)

        XCTAssertNil(state.rule)
        XCTAssertNil(state.batch)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile(in: metadata).path)
        )
    }

    // MARK: - 往返

    func testRuleAndBatchRoundTripThroughARecreatedStore() async throws {
        let metadata = try makeDirectory()
        let rule = try makeRule(
            contentScope: .includingTag("project"),
            timeScope: .pastThreeMonths,
            dailyCount: 12
        )
        let batch = makeBatch(
            vaultID: vaultID,
            rule: rule,
            orderedPaths: ["Projects/Plan.md", "Ideas/Idea.md"]
        )
        let firstStore = try ReviewStateStore(metadataDirectory: metadata)

        try await firstStore.save(vaultID: vaultID, rule: rule)
        let afterRuleSave = try await firstStore.load(vaultID: vaultID)
        try await firstStore.save(vaultID: vaultID, batch: batch)
        let reloadedStore = try ReviewStateStore(metadataDirectory: metadata)
        let reloaded = try await reloadedStore.load(vaultID: vaultID)

        XCTAssertEqual(afterRuleSave.rule, rule)
        XCTAssertNil(afterRuleSave.batch)
        XCTAssertEqual(reloaded.rule, rule)
        XCTAssertEqual(reloaded.batch, batch)
    }

    func testSavingARuleKeepsTheStoredBatchForTheCallerToInvalidate() async throws {
        let metadata = try makeDirectory()
        let store = try ReviewStateStore(metadataDirectory: metadata)
        let firstRule = try makeRule(dailyCount: 4)
        let secondRule = try makeRule(dailyCount: 8)
        let batch = makeBatch(vaultID: vaultID, rule: firstRule, orderedPaths: ["A.md"])
        try await store.save(vaultID: vaultID, rule: firstRule)
        try await store.save(vaultID: vaultID, batch: batch)

        try await store.save(vaultID: vaultID, rule: secondRule)
        let state = try await store.load(vaultID: vaultID)

        XCTAssertEqual(state.rule, secondRule)
        XCTAssertEqual(state.batch, batch)
    }

    // MARK: - 覆盖保存

    func testOverwritingSaveLeavesNoTemporaryFiles() async throws {
        let metadata = try makeDirectory()
        let store = try ReviewStateStore(metadataDirectory: metadata)
        let firstBatch = makeBatch(
            vaultID: vaultID,
            rule: try makeRule(),
            orderedPaths: ["A.md"]
        )
        let secondBatch = makeBatch(
            vaultID: vaultID,
            rule: try makeRule(),
            orderedPaths: ["B.md", "C.md"]
        )

        try await store.save(vaultID: vaultID, batch: firstBatch)
        try await store.save(vaultID: vaultID, batch: secondBatch)
        let firstBytes = try Data(contentsOf: stateFile(in: metadata))
        try await store.save(vaultID: vaultID, batch: secondBatch)
        let secondBytes = try Data(contentsOf: stateFile(in: metadata))
        let contents = try FileManager.default.contentsOfDirectory(atPath: metadata.path)
        let state = try await store.load(vaultID: vaultID)

        XCTAssertEqual(contents, ["review-state.json"])
        XCTAssertEqual(firstBytes, secondBytes)
        XCTAssertEqual(state.batch, secondBatch)
    }

    // MARK: - 删除

    func testDeleteClearsStateAndSubsequentLoadsAreEmpty() async throws {
        let metadata = try makeDirectory()
        let store = try ReviewStateStore(metadataDirectory: metadata)
        try await store.save(vaultID: vaultID, rule: try makeRule())

        try await store.delete(vaultID: vaultID)
        let afterDelete = try await store.load(vaultID: vaultID)
        try await store.delete(vaultID: vaultID)

        XCTAssertNil(afterDelete.rule)
        XCTAssertNil(afterDelete.batch)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile(in: metadata).path)
        )
    }

    // MARK: - Vault 隔离

    func testTwoVaultsDoNotReadEachOthersState() async throws {
        let firstMetadata = try makeDirectory()
        let secondMetadata = try makeDirectory()
        let firstStore = try ReviewStateStore(metadataDirectory: firstMetadata)
        let secondStore = try ReviewStateStore(metadataDirectory: secondMetadata)
        let firstRule = try makeRule(
            contentScope: .includingTag("project"),
            dailyCount: 8
        )
        let secondRule = try makeRule(contentScope: .untagged, dailyCount: 4)
        let firstBatch = makeBatch(
            vaultID: vaultID,
            rule: firstRule,
            orderedPaths: ["Projects/Plan.md"]
        )

        try await firstStore.save(vaultID: vaultID, rule: firstRule)
        try await firstStore.save(vaultID: vaultID, batch: firstBatch)
        try await secondStore.save(vaultID: otherVaultID, rule: secondRule)

        let secondState = try await secondStore.load(vaultID: otherVaultID)
        let firstState = try await firstStore.load(vaultID: vaultID)

        XCTAssertNil(secondState.batch)
        XCTAssertEqual(secondState.rule, secondRule)
        XCTAssertEqual(firstState.rule, firstRule)
        XCTAssertEqual(firstState.batch, firstBatch)
        XCTAssertNotEqual(
            try Data(contentsOf: stateFile(in: firstMetadata)),
            try Data(contentsOf: stateFile(in: secondMetadata))
        )
    }

    func testBatchOfAnotherVaultIsNeitherAcceptedNorReturned() async throws {
        let metadata = try makeDirectory()
        let store = try ReviewStateStore(metadataDirectory: metadata)
        let foreignBatch = makeBatch(
            vaultID: otherVaultID,
            rule: try makeRule(),
            orderedPaths: ["Foreign.md"]
        )

        do {
            try await store.save(vaultID: vaultID, batch: foreignBatch)
            XCTFail("Expected \(ReviewStateStoreError.vaultMismatch)")
        } catch {
            XCTAssertEqual(error as? ReviewStateStoreError, .vaultMismatch)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: stateFile(in: metadata).path)
        )

        let ownBatch = makeBatch(
            vaultID: vaultID,
            rule: try makeRule(),
            orderedPaths: ["Own.md"]
        )
        try await store.save(vaultID: vaultID, batch: ownBatch)
        let foreignView = try await store.load(vaultID: otherVaultID)
        let ownView = try await store.load(vaultID: vaultID)

        XCTAssertNil(foreignView.batch)
        XCTAssertEqual(ownView.batch, ownBatch)
    }

    // MARK: - Vault 字节不变

    func testVaultDirectoryStaysByteIdentical() async throws {
        let vaultRoot = try makeDirectory()
        let notes = vaultRoot.appendingPathComponent("Notes", isDirectory: true)
        let subfolder = notes.appendingPathComponent("Sub", isDirectory: true)
        try createDirectory(subfolder)
        let alpha = notes.appendingPathComponent("Alpha.md")
        let beta = subfolder.appendingPathComponent("Beta.md")
        let alphaBytes = Data("# Alpha\n\n正文内容，不动一个字节。\n".utf8)
        let betaBytes = Data("---\ntags:\n  - project\n---\n\n# Beta\n".utf8)
        try alphaBytes.write(to: alpha)
        try betaBytes.write(to: beta)
        let metadata = vaultRoot.appendingPathComponent("Metadata", isDirectory: true)
        try createDirectory(metadata)
        let before = try bytesOutsideMetadata(in: vaultRoot)
        let store = try ReviewStateStore(metadataDirectory: metadata)

        _ = try await store.load(vaultID: vaultID)
        try await store.save(vaultID: vaultID, rule: try makeRule())
        try await store.save(vaultID: vaultID, batch: makeBatch(
            vaultID: vaultID,
            rule: try makeRule(),
            orderedPaths: ["Notes/Alpha.md"]
        ))
        _ = try await store.load(vaultID: vaultID)
        try await store.delete(vaultID: vaultID)
        try await store.save(vaultID: vaultID, rule: try makeRule())

        XCTAssertEqual(try bytesOutsideMetadata(in: vaultRoot), before)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stateFile(in: metadata).path)
        )
    }

    // MARK: - 失败闭合

    func testCorruptStateFileFailsClosedWithoutBeingClobbered() async throws {
        let metadata = try makeDirectory()
        let state = stateFile(in: metadata)
        let original = Data(#"{"rule":{"contentScope":"all""#.utf8)
        try original.write(to: state)
        let store = try ReviewStateStore(metadataDirectory: metadata)

        await assertThrows(.invalidState) {
            _ = try await store.load(vaultID: vaultID)
        }
        await assertThrows(.invalidState) {
            try await store.save(vaultID: vaultID, rule: try makeRule())
        }

        XCTAssertEqual(try Data(contentsOf: state), original)
    }

    func testOversizedStateFileFailsClosed() async throws {
        let metadata = try makeDirectory()
        let state = stateFile(in: metadata)
        var oversized = Data(#"{"batch":null,"rule":null}"#.utf8)
        oversized.append(
            Data(repeating: 0x20, count: 1_048_576 + 1 - oversized.count)
        )
        try oversized.write(to: state)
        let store = try ReviewStateStore(metadataDirectory: metadata)

        await assertThrows(.stateFileTooLarge) {
            _ = try await store.load(vaultID: vaultID)
        }
        await assertThrows(.stateFileTooLarge) {
            try await store.save(vaultID: vaultID, rule: try makeRule())
        }

        XCTAssertEqual(try Data(contentsOf: state), oversized)
    }

    func testStateFileSymbolicLinkIsNeverReadOrOverwritten() async throws {
        let parent = try makeDirectory()
        let metadata = parent.appendingPathComponent("Metadata", isDirectory: true)
        try createDirectory(metadata)
        let target = parent.appendingPathComponent("review-state-target.json")
        let stable = Data(#"{"batch":null,"rule":null}"#.utf8)
        try stable.write(to: target)
        let store = try ReviewStateStore(metadataDirectory: metadata)
        try FileManager.default.createSymbolicLink(
            at: stateFile(in: metadata),
            withDestinationURL: target
        )

        await assertThrows(.stateFileIsNotRegular) {
            _ = try await store.load(vaultID: vaultID)
        }
        await assertThrows(.stateFileIsNotRegular) {
            try await store.save(vaultID: vaultID, rule: try makeRule())
        }

        XCTAssertEqual(try Data(contentsOf: target), stable)
    }
}

extension ReviewStateStoreTests {
    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createDirectory(directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func createDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
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

    private func makeBatch(
        vaultID: UUID,
        rule: ReviewRule,
        orderedPaths: [String]
    ) -> ReviewBatch {
        ReviewBatch(
            vaultID: vaultID,
            day: ReviewBatch.localDay(from: now, calendar: calendar),
            rule: rule,
            orderedPaths: orderedPaths
        )
    }

    private func bytesOutsideMetadata(in vaultRoot: URL) throws -> [String: Data] {
        // 临时目录在 macOS 上经 /private/var 符号链接，先解析再比较前缀。
        let root = vaultRoot.resolvingSymlinksInPath().path
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        while let item = enumerator?.nextObject() as? URL {
            let path = item.resolvingSymlinksInPath().path
            guard path.hasPrefix(root), path.count > root.count else { continue }
            let relativePath = String(path.dropFirst(root.count + 1))
            if relativePath == "Metadata" {
                enumerator?.skipDescendants()
                continue
            }
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(
                atPath: item.path,
                isDirectory: &isDirectory
            )
            guard !isDirectory.boolValue else { continue }
            result[relativePath] = try Data(contentsOf: item)
        }
        return result
    }

    private func assertThrows(
        _ expected: ReviewStateStoreError,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ReviewStateStoreError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
