import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

/// The tracker turns visible-block geometry into a source-coordinate snapshot
/// (reader → editor) and turns a source offset back into a restore target
/// (editor → reader). All decisions are pure functions over frames and
/// entries; the SwiftUI plumbing only feeds them.
@MainActor
final class ReaderViewportTrackerTests: XCTestCase {
    // MARK: - Topmost visible block (reader → editor)

    func testTopmostVisibleFrameIsTheFirstBlockNotEntirelyAboveTheViewportTop() {
        // Frames live in the reader scroll coordinate space, whose viewport
        // top edge is always y = 0.
        let frames = [
            frame(0, minY: -500, maxY: -200),
            frame(1, minY: -184, maxY: 96),
            frame(2, minY: 112, maxY: 320),
            frame(3, minY: 336, maxY: 700),
        ]

        XCTAssertEqual(ReaderViewportTracker.topmostVisibleFrame(frames)?.entryIndex, 1)
    }

    func testViewportTopInsideGapBetweenBlocksSelectsTheBlockBelow() {
        let frames = [
            frame(0, minY: -400, maxY: -100),
            frame(1, minY: -84, maxY: -16),
            frame(2, minY: 8, maxY: 300),
        ]

        let topmost = ReaderViewportTracker.topmostVisibleFrame(frames)

        XCTAssertEqual(topmost?.entryIndex, 2)
        XCTAssertEqual(topmost?.minY, 8, "The positive gap offset must be recorded")
    }

    func testViewportAtTheVeryTopSelectsTheFirstFrameWithZeroOffset() {
        let frames = [
            frame(0, minY: 0, maxY: 240),
            frame(1, minY: 256, maxY: 480),
        ]

        let topmost = ReaderViewportTracker.topmostVisibleFrame(frames)

        XCTAssertEqual(topmost?.entryIndex, 0)
        XCTAssertEqual(topmost?.minY, 0)
    }

    func testSparseUnsortedRealizedFramesStillResolve() {
        // LazyVStack reports only realized anchors and preference reduction
        // does not guarantee order.
        let frames = [
            frame(5, minY: 900, maxY: 1200),
            frame(2, minY: -80, maxY: 40),
            frame(7, minY: 1400, maxY: 1600),
        ]

        XCTAssertEqual(ReaderViewportTracker.topmostVisibleFrame(frames)?.entryIndex, 2)
    }

    func testAllFramesAboveTheViewportSelectNothing() {
        let frames = [frame(0, minY: -300, maxY: -100)]

        XCTAssertNil(ReaderViewportTracker.topmostVisibleFrame(frames))
    }

    // MARK: - Snapshot from entries

    func testSnapshotCarriesAnchorOffsetBlockRangeAndPathFromRealEntries() throws {
        let entries = try makeEntries()
        XCTAssertGreaterThanOrEqual(entries.count, 5)
        let path = try makePath()

        // The top edge sits 40pt into the third block.
        let frames = [
            frame(0, minY: -600, maxY: -480),
            frame(1, minY: -464, maxY: -300),
            frame(2, minY: -284, maxY: -120),
            frame(3, minY: -104, maxY: 260),
            frame(4, minY: 276, maxY: 600),
        ]

        let snapshot = ReaderViewportTracker.snapshot(frames: frames, entries: entries, path: path)

        XCTAssertEqual(snapshot?.path, path)
        XCTAssertEqual(snapshot?.anchorSourceOffset, entries[3].sourceRange.lowerBound)
        XCTAssertEqual(snapshot?.blockSourceRange, entries[3].sourceRange)
        XCTAssertEqual(snapshot?.verticalOffset, -104)
    }

    func testSnapshotIsNilWithoutFramesOrWithoutProvenance() throws {
        let entries = try makeEntries()

        XCTAssertNil(
            ReaderViewportTracker.snapshot(frames: [], entries: entries, path: try makePath())
        )

        let unanchored = [MarkdownRenderBlockEntry(sourceRange: 0..<0, block: .thematicBreak)]
        XCTAssertNil(
            ReaderViewportTracker.snapshot(
                frames: [frame(0, minY: -10, maxY: 10)],
                entries: unanchored,
                path: try makePath()
            ),
            "An entry without a proven source range must not become a restore anchor"
        )
    }

    func testSnapshotRejectsOutOfRangeFrameIndexes() throws {
        let frames = [frame(9, minY: -10, maxY: 10)]

        XCTAssertNil(
            ReaderViewportTracker.snapshot(frames: frames, entries: [], path: try makePath())
        )
    }

    // MARK: - Restore target (editor → reader)

    func testEntryIndexContainingResolvesOffsetsInsideGapsAndTail() throws {
        let entries = try makeEntries()
        let bytes = try makeSourceBytes()

        // Inside the third block.
        let inside = entries[2].sourceRange.lowerBound + 2
        XCTAssertEqual(ReaderViewportTracker.entryIndex(containing: inside, in: entries), 2)

        // In the blank-line gap between the third and fourth block: the block
        // above the gap is the content the reader was showing.
        let gap = entries[2].sourceRange.upperBound + 1
        XCTAssertLessThan(gap, entries[3].sourceRange.lowerBound)
        XCTAssertEqual(ReaderViewportTracker.entryIndex(containing: gap, in: entries), 2)

        // Past the end of the document body: the last block.
        XCTAssertEqual(
            ReaderViewportTracker.entryIndex(containing: bytes.count + 50, in: entries),
            entries.count - 1
        )
    }

    func testEntryIndexContainingReturnsNilBeforeTheFirstBlock() throws {
        let entries = try makeEntries()

        XCTAssertNil(ReaderViewportTracker.entryIndex(containing: 0, in: entries))
    }

    // MARK: - Fixtures

    /// A long multi-block document with frontmatter, headings, paragraphs,
    /// a list and a quote — enough variety for anchor byte checks.
    private static let source = """
        ---
        title: 位置连续性
        ---

        # 开头标题

        开头的段落，提供文档顶部的锚点。

        ## 第二节

        第二节的正文内容，用来覆盖中部锚点。

        > 引用块也在锚点集合里。

        - 列表项一
        - 列表项二

        ## 第三节

        第三节的正文内容。

        ```swift
        let code = "fence"
        ```

        # 尾部标题

        尾部段落，覆盖文档末尾的锚点。
        """

    private func makePath() throws -> VaultPath {
        try VaultPath(decodedRelativePath: "Tracker/笔记.md")
    }

    private func makeSourceBytes() throws -> Data {
        Data(Self.source.utf8)
    }

    private func makeEntries() throws -> [MarkdownRenderBlockEntry] {
        let note = try MarkdownNoteParser.parse(
            makeSourceBytes(),
            at: makePath()
        )
        return MarkdownReaderRenderer.render(note).entries
    }

    private func frame(_ index: Int, minY: CGFloat, maxY: CGFloat) -> ReaderBlockFrame {
        ReaderBlockFrame(entryIndex: index, minY: minY, maxY: maxY)
    }
}
