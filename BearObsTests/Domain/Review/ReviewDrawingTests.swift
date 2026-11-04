import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsDomain
#else
    @testable import BearObs
#endif

final class ReviewDrawingTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
    }

    private func candidate(
        _ path: String,
        modifiedAt: Date? = nil,
        tags: Set<String> = [],
        isReadable: Bool = true
    ) -> ReviewCandidate {
        ReviewCandidate(
            path: path,
            modifiedAt: modifiedAt ?? now,
            tags: tags,
            isReadable: isReadable
        )
    }

    // MARK: - ReviewRule

    func testDefaultRuleHasDailyCountEightAndIsSubmittable() throws {
        let rule = try ReviewRule()

        XCTAssertEqual(rule.dailyCount, 8)
        XCTAssertTrue(rule.isSubmittable)
    }

    func testIncludingTagWithEmptyStringIsNotSubmittable() throws {
        let rule = try ReviewRule(contentScope: .includingTag(""))

        XCTAssertFalse(rule.isSubmittable)
    }

    func testDailyCountOnlyAllowsMultiplesOfFourBetweenFourAndTwentyFour() throws {
        for allowed in [4, 8, 12, 16, 20, 24] {
            XCTAssertNoThrow(try ReviewRule(dailyCount: allowed), String(allowed))
        }
        for rejected in [0, 3, 5, 28, -4] {
            XCTAssertThrowsError(try ReviewRule(dailyCount: rejected), String(rejected))
        }
    }

    // MARK: - 候选过滤

    func testPastMonthCutoffExcludesCandidatesOlderThanLowerBound() throws {
        let rule = try ReviewRule(timeScope: .pastMonth)
        let candidates = [
            candidate(
                "older.md",
                modifiedAt: calendar.date(byAdding: .day, value: -45, to: now)!
            ),
            candidate(
                "recent.md",
                modifiedAt: calendar.date(byAdding: .day, value: -7, to: now)!
            ),
        ]

        let drawn = ReviewDrawing.draw(
            candidates: candidates,
            rule: rule,
            seed: 1,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(drawn, ["recent.md"])
        XCTAssertNil(ReviewRule.TimeScope.all.cutoff(from: now, calendar: calendar))
    }

    func testIncludingTagMatchesFullTagIdentityOnly() throws {
        let rule = try ReviewRule(contentScope: .includingTag("project"))
        let candidates = [
            candidate("exact.md", tags: ["project"]),
            candidate("child.md", tags: ["project/mobile"]),
            candidate("mixed.md", tags: ["project", "other"]),
        ]

        let drawn = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 1)

        XCTAssertEqual(Set(drawn), ["exact.md", "mixed.md"])
    }

    func testExcludingTagMatchesFullTagIdentityOnly() throws {
        let rule = try ReviewRule(contentScope: .excludingTag("project"))
        let candidates = [
            candidate("exact.md", tags: ["project"]),
            candidate("child.md", tags: ["project/mobile"]),
            candidate("untouched.md", tags: ["work"]),
        ]

        let drawn = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 1)

        XCTAssertEqual(Set(drawn), ["child.md", "untouched.md"])
    }

    func testUntaggedScopeKeepsOnlyCandidatesWithoutTags() throws {
        let rule = try ReviewRule(contentScope: .untagged)
        let candidates = [
            candidate("no-tags.md"),
            candidate("tagged.md", tags: ["journal"]),
        ]

        let drawn = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 1)

        XCTAssertEqual(drawn, ["no-tags.md"])
    }

    func testUnreadableCandidatesNeverEnterResults() throws {
        let rule = try ReviewRule()
        let candidates = [
            candidate("broken.md", tags: ["project"], isReadable: false),
            candidate("fine.md", tags: ["project"]),
        ]

        let drawn = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 1)

        XCTAssertEqual(drawn, ["fine.md"])
    }

    func testFewerCandidatesThanDailyCountReturnsAll() throws {
        let rule = try ReviewRule(dailyCount: 8)
        let candidates = [
            candidate("a.md", tags: ["x"]),
            candidate("b.md", tags: ["y"]),
            candidate("c.md", tags: ["z"]),
        ]

        let drawn = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 7)

        XCTAssertEqual(drawn.count, 3)
        XCTAssertEqual(Set(drawn), ["a.md", "b.md", "c.md"])
    }

    // MARK: - 稳定洗牌

    func testSameSeedReproducesExactOrderAndDifferentSeedIsAllowedToDiffer() throws {
        let rule = try ReviewRule(dailyCount: 8)
        let candidates = (0..<24).map { index in
            candidate(
                "note-\(index).md",
                tags: index.isMultiple(of: 2) ? ["even"] : ["odd"]
            )
        }

        let first = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 42)
        let second = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 42)
        let otherSeed = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 43)

        XCTAssertEqual(first, second)
        XCTAssertEqual(otherSeed.count, rule.dailyCount)
    }

    func testResultIsBoundedByDailyCountAndDrawnFromCandidates() throws {
        let rule = try ReviewRule(dailyCount: 12)
        let candidates = (0..<30).map { index in
            candidate("note-\(index).md", tags: ["pool"])
        }

        let drawn = ReviewDrawing.draw(candidates: candidates, rule: rule, seed: 9)

        XCTAssertEqual(drawn.count, rule.dailyCount)
        let candidatePaths = Set(candidates.map(\.path))
        XCTAssertTrue(drawn.allSatisfy(candidatePaths.contains))
        XCTAssertEqual(Set(drawn).count, drawn.count)
    }

    // MARK: - ReviewBatch

    func testBatchLocalDayKeepsOnlyYearMonthDay() {
        var calendar = self.calendar
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(
            from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 30)
        )!

        let day = ReviewBatch.localDay(from: date, calendar: calendar)

        XCTAssertEqual(day.year, 2026)
        XCTAssertEqual(day.month, 11)
        XCTAssertEqual(day.day, 3)
        XCTAssertNil(day.hour)
        XCTAssertNil(day.calendar)
        XCTAssertNil(day.timeZone)
    }

    func testBatchNormalizesDayAndComparesByVaultAndDay() throws {
        let vaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let rule = try ReviewRule()
        let paddedDay = ReviewBatch.localDay(
            from: calendar.date(from: DateComponents(year: 2026, month: 11, day: 3))!,
            calendar: calendar
        )
        var dayWithExtras = paddedDay
        dayWithExtras.hour = 8
        dayWithExtras.calendar = calendar
        dayWithExtras.timeZone = calendar.timeZone

        let batch = ReviewBatch(
            vaultID: vaultID,
            day: dayWithExtras,
            rule: rule,
            orderedPaths: ["a.md"]
        )
        let sameFields = ReviewBatch(
            vaultID: vaultID,
            day: paddedDay,
            rule: rule,
            orderedPaths: ["a.md"]
        )
        let otherVault = ReviewBatch(
            vaultID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            day: paddedDay,
            rule: rule,
            orderedPaths: ["a.md"]
        )

        XCTAssertEqual(batch.day.year, 2026)
        XCTAssertEqual(batch.day.month, 11)
        XCTAssertEqual(batch.day.day, 3)
        XCTAssertNil(batch.day.hour)
        XCTAssertEqual(batch.day, paddedDay)
        XCTAssertEqual(batch, sameFields)
        XCTAssertNotEqual(batch, otherVault)
    }
}
