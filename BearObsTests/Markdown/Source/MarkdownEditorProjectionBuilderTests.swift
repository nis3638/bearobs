import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsDomain
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownEditorProjectionBuilderTests: XCTestCase {
    func testBuildsRunsForEveryStructuredNodeKind() throws {
        let text =
            "# 标题\n普通段落\n- 条目\n- [ ] 待办\n> 引用\n```\ncode\n```\n<!-- 未知 -->\n"
        let data = Data(text.utf8)

        let projection = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: text, snapshot: nil))

        XCTAssertEqual(projection.text, text)
        XCTAssertEqual(
            projection.runs.map(\.token),
            [
                .heading(level: 1),
                .listItem,
                .listItem,
                .taskMarker,
                .quote,
                .codeBlock,
                .opaque,
            ])
        XCTAssertEqual(
            projection.runs.map { String(decoding: data.subdata(in: $0.range), as: UTF8.self) },
            [
                "# 标题\n",
                "- 条目\n",
                "- [ ] 待办\n",
                "[ ]",
                "> 引用\n",
                "```\ncode\n```\n",
                "<!-- 未知 -->\n",
            ])
    }

    func testHeadingLevelCarriesThroughToTheToken() throws {
        let text = "## 二级\n"

        let projection = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: text, snapshot: nil))

        XCTAssertEqual(projection.runs.map(\.token), [.heading(level: 2)])
    }

    func testPlainParagraphsProduceNoRun() throws {
        let text = "中文段落一\n中文段落二\n"

        let projection = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: text, snapshot: nil))

        XCTAssertEqual(projection.runs, [])
    }

    func testEveryRunRangeIsAWholeScalarUTF8SliceOfTheText() throws {
        let text = "# 中文😀e\u{301}\r\n- [x] 任务🐻\r\n> 引用\r\n"
        let data = Data(text.utf8)
        let map = MarkdownTextCoordinateMap(text: text)

        let projection = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: text, snapshot: nil))

        XCTAssertFalse(projection.runs.isEmpty)
        for run in projection.runs {
            XCTAssertGreaterThanOrEqual(run.range.lowerBound, 0)
            XCTAssertLessThanOrEqual(run.range.upperBound, data.count)
            XCTAssertNotNil(
                String(data: data.subdata(in: run.range), encoding: .utf8),
                "run range split a UTF-8 scalar: \(run.range)")
            XCTAssertNotNil(
                map.utf16Range(forUTF8: run.range),
                "run range split a UTF-16 scalar: \(run.range)")
        }
    }

    func testSnapshotFastPathMatchesDraftParseAfterBOMShift() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let data = bom + Data("---\ntitle: 原题\n---\n# 标题\n- [ ] 任务\n".utf8)
        let snapshot = try MarkdownSourceMapParser.parse(data)

        let fromSnapshot = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: snapshot.text, snapshot: snapshot))
        let fromDraft = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: snapshot.text, snapshot: nil))

        XCTAssertEqual(fromSnapshot, fromDraft)
        XCTAssertEqual(
            fromSnapshot.runs.map {
                String(decoding: Data(snapshot.text.utf8).subdata(in: $0.range), as: UTF8.self)
            },
            ["---\ntitle: 原题\n---\n", "# 标题\n", "- [ ] 任务\n", "[ ]"]
        )
    }

    func testEditedDraftReparsesRunsForTheDisplayedText() throws {
        let data = Data("# 标题\n- [ ] 任务\n".utf8)
        let snapshot = try MarkdownSourceMapParser.parse(data)
        let prefix = "新增段落\n"
        let edited = prefix + snapshot.text

        let projection = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: edited, snapshot: snapshot))

        XCTAssertEqual(
            projection.runs.map {
                String(decoding: Data(edited.utf8).subdata(in: $0.range), as: UTF8.self)
            },
            ["# 标题\n", "- [ ] 任务\n", "[ ]"]
        )
    }

    func testProjectionDoesNotMutateOrDependOnSnapshotIdentity() throws {
        let data = Data("- [ ] 任务\n".utf8)
        let snapshot = try MarkdownSourceMapParser.parse(data)

        let projection = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(text: snapshot.text, snapshot: snapshot))

        XCTAssertEqual(snapshot.data, data)
        XCTAssertEqual(
            projection.runs.map(\.token),
            [.listItem, .taskMarker]
        )
    }

    func testOneMegabyteDocumentBuildsWithinTheLatencyBudget() throws {
        let paragraph =
            "第N段：中文内容、english words、emoji 😀、combining e\u{301}，"
            + "以及一段较长的尾随文字用于覆盖真实笔记的行宽。\n"
        var text = ""
        text.reserveCapacity((1 << 20) + paragraph.utf8.count)
        while text.utf8.count < 1 << 20 {
            text += paragraph
        }
        XCTAssertGreaterThanOrEqual(text.utf8.count, 1 << 20)

        let clock = ContinuousClock()
        var durations: [Duration] = []
        for _ in 0..<9 {
            let start = clock.now
            let projection = MarkdownEditorProjectionBuilder.build(text: text, snapshot: nil)
            durations.append(start.duration(to: clock.now))
            XCTAssertNotNil(projection)
        }
        let p95 = durations.sorted()[8]

        XCTAssertLessThan(p95, .seconds(1))
        print(
            "EDITOR_PROJECTION_MEASUREMENT bytes=\(text.utf8.count) "
                + "p95_ms=\(String(format: "%.1f", milliseconds(p95)))")
    }

    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }
}
