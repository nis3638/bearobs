import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

final class CardFeedModelTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_767_225_600)

    private func summary(
        _ path: String,
        title: String = "",
        preview: String = "",
        modifiedAt: Date? = nil,
        parseStatus: IndexedNoteParseStatus = .complete
    ) throws -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: try VaultPath(decodedRelativePath: path),
            title: title,
            preview: preview,
            modifiedAt: modifiedAt ?? referenceDate,
            parseStatus: parseStatus
        )
    }

    private func card(
        _ path: String,
        title: String = "",
        preview: String = "",
        tags: [String] = [],
        parseStatus: IndexedNoteParseStatus = .complete
    ) throws -> Card {
        CardFeedModel.card(
            from: try summary(
                path,
                title: title,
                preview: preview,
                parseStatus: parseStatus
            ),
            tags: tags
        )
    }

    // MARK: - 标题回退

    func testEmptyTitleFallsBackToFileNameWithoutExtension() throws {
        let card = try card("Notes/2026/每周回顾.md", title: "")

        XCTAssertEqual(card.title, "每周回顾")
    }

    func testNonEmptyTitleIsKeptAsIs() throws {
        let card = try card("Notes/idea.md", title: "已经起好的标题")

        XCTAssertEqual(card.title, "已经起好的标题")
    }

    // MARK: - 摘要 140 字形簇截断

    func testExcerptOfExactly140ClustersIsNotTruncated() throws {
        let preview = String(repeating: "字", count: 140)

        let card = try card("note.md", preview: preview)

        XCTAssertEqual(card.excerpt, preview)
        XCTAssertEqual(card.excerpt.count, 140)
        XCTAssertFalse(card.excerpt.hasSuffix("…"))
    }

    func testExcerptOf141ClustersIsTruncatedWithEllipsis() throws {
        let preview = String(repeating: "字", count: 141)

        let card = try card("note.md", preview: preview)

        XCTAssertEqual(card.excerpt, String(repeating: "字", count: 140) + "…")
        XCTAssertEqual(card.excerpt.count, 141)
    }

    func testTruncationNeverSplitsMultiScalarEmojiClusters() throws {
        // 家庭 emoji 是 1 个扩展字形簇，由 7 个 Unicode 标量组成。
        let familyEmoji = "👨‍👩‍👧‍👦"
        XCTAssertEqual(familyEmoji.count, 1)

        // 139 个字母 + 家庭 emoji = 140 簇，恰好不截断，emoji 必须完整保留。
        let full = String(repeating: "a", count: 139) + familyEmoji
        let fullCard = try card("note.md", preview: full)
        XCTAssertEqual(fullCard.excerpt, full)
        XCTAssertEqual(fullCard.excerpt.count, 140)
        XCTAssertTrue(fullCard.excerpt.hasSuffix(familyEmoji))

        // 139 个字母 + 家庭 emoji + 1 个字母 = 141 簇，截断点落在 emoji 之后。
        let overflowing = full + "b"
        let truncatedCard = try card("note.md", preview: overflowing)
        XCTAssertEqual(truncatedCard.excerpt, full + "…")
        XCTAssertEqual(truncatedCard.excerpt.count, 141)
        XCTAssertTrue(truncatedCard.excerpt.contains(familyEmoji))
    }

    // MARK: - 标签折叠

    func testFiveTagsShowFirstThreeInOrderWithExtraCountTwo() throws {
        let card = try card(
            "note.md",
            tags: ["journal", "project", "reading", "work", "archive"]
        )

        XCTAssertEqual(card.visibleTags, ["journal", "project", "reading"])
        XCTAssertEqual(card.extraTagCount, 2)
    }

    func testAtMostThreeTagsLeaveNoExtraCount() throws {
        let card = try card("note.md", tags: ["journal", "project"])

        XCTAssertEqual(card.visibleTags, ["journal", "project"])
        XCTAssertEqual(card.extraTagCount, 0)
    }

    // MARK: - 失败笔记降级

    func testFailedParseStatusReplacesExcerptWithFixedCopyAndMarksUnreadable() throws {
        let card = try card(
            "broken.md",
            preview: "本应显示的正文摘要",
            tags: ["journal"],
            parseStatus: .failed
        )

        XCTAssertEqual(card.excerpt, CardFeedCopy.unreadableExcerpt)
        XCTAssertEqual(card.readability, .unreadable)
        // 失败笔记仍保留标题、标签等其余卡片信息。
        XCTAssertEqual(card.title, "broken")
        XCTAssertEqual(card.visibleTags, ["journal"])
    }

    func testDegradedParseStatusStaysReadableWithNormalExcerpt() throws {
        let card = try card(
            "degraded.md",
            title: "降级",
            preview: "仍然可以阅读的摘要",
            parseStatus: .degraded
        )

        XCTAssertEqual(card.readability, .readable)
        XCTAssertEqual(card.excerpt, "仍然可以阅读的摘要")
    }

    // MARK: - 标签过滤（完整身份精确匹配）

    func testTagFilteringUsesExactFullIdentityMatch() throws {
        let exact = try card("exact.md", tags: ["project"])
        let childOnly = try card("child.md", tags: ["project/mobile"])
        let exactPlusOther = try card("mixed.md", tags: ["project", "other"])
        let unrelated = try card("other.md", tags: ["mobile"])
        let cards = [exact, childOnly, exactPlusOther, unrelated]
        let tagsByPath = [
            exact.path: ["project"],
            childOnly.path: ["project/mobile"],
            exactPlusOther.path: ["project", "other"],
            unrelated.path: ["mobile"],
        ]

        let filtered = CardFeedModel.filtering(cards, byTag: "project", tagsByPath: tagsByPath)

        XCTAssertEqual(filtered.map(\.path), [exact.path, exactPlusOther.path])
    }

    func testTagFilteringConsidersTagsBeyondTheVisibleThree() throws {
        let card = try card(
            "deep.md",
            tags: ["a", "b", "c", "project"]
        )
        let tagsByPath = [card.path: ["a", "b", "c", "project"]]

        let filtered = CardFeedModel.filtering([card], byTag: "project", tagsByPath: tagsByPath)

        XCTAssertEqual(filtered.map(\.path), [card.path])
    }

    // MARK: - 搜索过滤

    func testSearchFilteringKeepsOnlyCardsWhosePathIsInMatchingSet() throws {
        let first = try card("first.md", title: "一")
        let second = try card("second.md", title: "二")
        let third = try card("third.md", title: "三")
        let cards = [first, second, third]

        let filtered = CardFeedModel.filtering(
            cards,
            bySearch: [second.path, third.path]
        )

        XCTAssertEqual(filtered.map(\.path), [second.path, third.path])
    }

    func testSearchFilteringWithEmptyMatchingSetReturnsNoCards() throws {
        let card = try card("note.md", title: "一")

        let filtered = CardFeedModel.filtering([card], bySearch: [])

        XCTAssertTrue(filtered.isEmpty)
    }
}
