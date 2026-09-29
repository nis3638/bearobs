import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsDomain
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownSourceMapParserTests: XCTestCase {
    func testBOMFrontmatterAndCRLFArePreservedInTheSnapshot() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let data = bom + Data("---\r\ntitle: 原题\r\n---\r\n正文🐻\r\n".utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)

        XCTAssertEqual(snapshot.data, data)
        XCTAssertEqual(snapshot.rawData, data)
        XCTAssertEqual(snapshot.text, "---\r\ntitle: 原题\r\n---\r\n正文🐻\r\n")
        XCTAssertEqual(snapshot.sourceInfo, .init(hasUTF8BOM: true, lineEnding: .crlf))
        XCTAssertEqual(snapshot.sourceMap.baselineHash, snapshot.contentHash)
        XCTAssertEqual(snapshot.sourceMap.nodes.first?.kind, .opaque)
        XCTAssertEqual(snapshot.sourceMap.nodes.first?.sourceRange.lowerBound, 0)
        XCTAssertTrue(snapshot.sourceMap.nodes.first?.isOpaque == true)
    }

    func testUnclosedFrontmatterMakesTheWholeDocumentOpaque() throws {
        let data = Data("---\ntitle: unfinished\n正文\n".utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)

        XCTAssertEqual(snapshot.sourceMap.nodes.count, 1)
        XCTAssertEqual(snapshot.sourceMap.nodes[0].sourceRange, 0..<data.count)
        XCTAssertEqual(snapshot.sourceMap.nodes[0].editableSpans, [])
        XCTAssertTrue(snapshot.sourceMap.nodes[0].isOpaque)
    }

    func testPlainParagraphExposesOnlyContentAndNotLineEnding() throws {
        let prefix = Data("\r\n".utf8)
        let content = Data("中文 😀 e\u{301}".utf8)
        let ending = Data("\r\n".utf8)
        let data = prefix + content + ending

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let paragraph = try XCTUnwrap(
            snapshot.sourceMap.nodes.first { $0.kind == .paragraph }
        )
        let span = try XCTUnwrap(paragraph.editableSpans.only)

        XCTAssertEqual(span.role, .text)
        XCTAssertEqual(span.range, prefix.count..<(prefix.count + content.count))
        XCTAssertEqual(span.expectedOriginal, content)
        XCTAssertEqual(paragraph.sourceRange, prefix.count..<data.count)
        XCTAssertFalse(paragraph.isOpaque)
    }

    func testHeadingExposesTitleWithoutMarkdownMarker() throws {
        let data = Data("### 标题🐻\n".utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let heading = try XCTUnwrap(snapshot.sourceMap.nodes.only)
        let span = try XCTUnwrap(heading.editableSpans.only)

        XCTAssertEqual(heading.kind, .heading(level: 3))
        XCTAssertEqual(span.role, .text)
        XCTAssertEqual(span.expectedOriginal, Data("标题🐻".utf8))
        XCTAssertEqual(span.range, 4..<(4 + Data("标题🐻".utf8).count))
    }

    func testHeadingLevelsRangeFromOneToSixAndDeeperMarksStayOpaque() throws {
        let source = "# 一\n## 二\n###### 六\n####### 七\n"
        let data = Data(source.utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let levels = snapshot.sourceMap.nodes.compactMap { node -> Int? in
            if case .heading(let level) = node.kind { return level }
            return nil
        }

        XCTAssertEqual(levels, [1, 2, 6])
        XCTAssertTrue(snapshot.sourceMap.nodes.contains { $0.isOpaque })
    }

    func testListItemsExposeOnlyTheTextAfterTheirMarker() throws {
        let source = "- \n- 苹果\n* 香蕉\n+ 橙子\n1. 葡萄\n2) 瓜\n  - 缩进项\n"
        let data = Data(source.utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let items = snapshot.sourceMap.nodes.filter { $0.kind == .listItem }

        XCTAssertEqual(items.count, 7)
        XCTAssertEqual(
            items.map { $0.editableSpans.only?.expectedOriginal },
            [
                nil,
                Data("苹果".utf8),
                Data("香蕉".utf8),
                Data("橙子".utf8),
                Data("葡萄".utf8),
                Data("瓜".utf8),
                Data("缩进项".utf8),
            ])
        XCTAssertTrue(items.allSatisfy { !$0.isOpaque })
        XCTAssertEqual(
            snapshot.sourceMap.nodes.reduce(0) { $0 + $1.sourceRange.count },
            data.count
        )
    }

    func testListItemsWithUnsafeOrStructuredContentStayOpaque() throws {
        let source = "- **粗体**\n- [链接](target)\n- - 嵌套列表\n- ---\n- 标题\n===\n"
        let data = Data(source.utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let items = snapshot.sourceMap.nodes.filter { $0.kind == .listItem }

        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(snapshot.sourceMap.nodes.allSatisfy(\.isOpaque))
    }

    func testQuotesExposeOnlyTheTextAfterTheirMarkers() throws {
        let source = "> 引用文字\n>text\n>> 嵌套引用\n>\n> - 列表\n> [!note] Callout\n"
        let data = Data(source.utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let quotes = snapshot.sourceMap.nodes.filter { $0.kind == .quote }

        XCTAssertEqual(quotes.count, 4)
        XCTAssertEqual(
            quotes.map { $0.editableSpans.only?.expectedOriginal },
            [
                Data("引用文字".utf8),
                Data("text".utf8),
                Data("嵌套引用".utf8),
                nil,
            ])
        XCTAssertTrue(quotes.allSatisfy { !$0.isOpaque })
        XCTAssertTrue(snapshot.sourceMap.nodes.contains { $0.isOpaque })
    }

    func testBareFencedBlocksBecomeCodeBlockNodesWithProvableBounds() throws {
        let source = "```\ncode 中文 😀\n继续\n```\n后文\n"
        let data = Data(source.utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let code = try XCTUnwrap(snapshot.sourceMap.nodes.first { $0.kind == .codeBlock })

        XCTAssertEqual(code.sourceRange, 0..<Data("```\ncode 中文 😀\n继续\n```\n".utf8).count)
        XCTAssertEqual(code.editableSpans, [])
        XCTAssertFalse(code.isOpaque)
        let paragraph = try XCTUnwrap(snapshot.sourceMap.nodes.first { $0.kind == .paragraph })
        XCTAssertEqual(
            paragraph.editableSpans.only?.expectedOriginal,
            Data("后文".utf8)
        )
    }

    func testTildeFencesWithoutInfoStringAlsoBecomeCodeBlockNodes() throws {
        let source = "~~~\ncode\n~~~\n"

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))

        XCTAssertEqual(snapshot.sourceMap.nodes.only?.kind, .codeBlock)
    }

    func testUnclosedBareFenceStaysOneCompleteCodeBlockNode() throws {
        let source = "```\n未闭合的代码"

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))

        let code = try XCTUnwrap(snapshot.sourceMap.nodes.only)
        XCTAssertEqual(code.kind, .codeBlock)
        XCTAssertEqual(code.sourceRange, 0..<Data(source.utf8).count)
    }

    func testTaskItemsExposeOnlyTheirThreeByteMarkers() throws {
        let data = Data("  - [ ] 第一项 ^keep\r\n12) [X] 第二项\n".utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)
        let tasks = snapshot.sourceMap.nodes.filter { $0.kind == .taskItem }

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0].editableSpans.only?.role, .taskMarker)
        XCTAssertEqual(tasks[0].editableSpans.only?.expectedOriginal, Data("[ ]".utf8))
        XCTAssertEqual(tasks[1].editableSpans.only?.expectedOriginal, Data("[X]".utf8))
        XCTAssertEqual(snapshot.sourceMap.editableSpans.count, 2)
    }

    func testUnsafeAndUnknownSyntaxRemainOpaque() throws {
        let source = """
            > [!note]+ Callout
            <!-- comment -->
            [[Target|Alias]]
            ![[image.png|300]]
            text #inline-tag
            plugin:: value
            ```dataview
            TABLE file.name
            ```
            """

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))

        XCTAssertFalse(snapshot.sourceMap.nodes.isEmpty)
        XCTAssertTrue(snapshot.sourceMap.nodes.allSatisfy(\.isOpaque))
        XCTAssertEqual(snapshot.sourceMap.editableSpans, [])
        XCTAssertEqual(
            snapshot.sourceMap.nodes.reduce(0) { $0 + $1.sourceRange.count },
            Data(source.utf8).count
        )
    }

    func testMultilineCommentsMathAndHTMLRemainOpaqueAsWholeBlocks() throws {
        let source = """
            %%
            secret words
            %%
            $$
            x + y
            $$
            <div class="plugin">
            visible-looking text
            </div>
            """

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))

        XCTAssertTrue(snapshot.sourceMap.nodes.allSatisfy(\.isOpaque))
        XCTAssertEqual(snapshot.sourceMap.editableSpans, [])
    }

    func testIndentedCodeCannotBeMisclassifiedAsATask() throws {
        let source = "    - [ ] literal code\n\t- [x] tabbed code\n   - [ ] actual task\n"

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))
        let tasks = snapshot.sourceMap.nodes.filter { $0.kind == .taskItem }

        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].editableSpans.only?.expectedOriginal, Data("[ ]".utf8))
    }

    func testReferenceLinksHighlightsAndObsidianCommentsRemainOpaque() throws {
        let source = """
            [label][reference]
            [reference]: /target
            ==highlight==
            %%hidden%%
            """

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))

        XCTAssertTrue(snapshot.sourceMap.nodes.allSatisfy(\.isOpaque))
        XCTAssertEqual(snapshot.sourceMap.editableSpans, [])
    }

    func testOddObsidianCommentDelimiterKeepsFollowingLinesOpaqueUntilClosed() throws {
        let source = "%% first %% %% second starts\nsecret words\n%%\nplain text\n"

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))
        let paragraphs = snapshot.sourceMap.nodes.filter { $0.kind == .paragraph }

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].editableSpans.only?.expectedOriginal, Data("plain text".utf8))
    }

    func testNestedHTMLRemainsOpaqueUntilTheOuterTagCloses() throws {
        let source = "<div>\n<div>\ninner\n</div>\nouter payload\n</div>\nplain text\n"

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))
        let paragraphs = snapshot.sourceMap.nodes.filter { $0.kind == .paragraph }

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].editableSpans.only?.expectedOriginal, Data("plain text".utf8))
    }

    func testTaskMarkerRequiresWhitespaceOrEndOfLineAfterClosingBracket() throws {
        let source = "- [ ]not-a-task\n- [x] actual task\n- [ ]\n"

        let snapshot = try MarkdownSourceMapParser.parse(Data(source.utf8))
        let tasks = snapshot.sourceMap.nodes.filter { $0.kind == .taskItem }

        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(
            tasks.map { $0.editableSpans.only?.expectedOriginal },
            [Data("[x]".utf8), Data("[ ]".utf8)])
    }

    func testEveryPublishedSpanIsAValidUTF8SliceOfOriginalData() throws {
        let data = Data("# 中文😀\r\n\r\nCafe\u{301} 内容\n- [x] 任务🐻\n".utf8)

        let snapshot = try MarkdownSourceMapParser.parse(data)

        for span in snapshot.sourceMap.editableSpans {
            XCTAssertEqual(data.subdata(in: span.range), span.expectedOriginal)
            XCTAssertNotNil(String(data: span.expectedOriginal, encoding: .utf8))
        }
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? self[0] : nil }
}

final class MarkdownDraftSyntaxResolverTests: XCTestCase {
    func testUneditedDraftWithBOMShiftsSnapshotRangesToVisibleText() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let data = bom + Data("---\ntitle: 原题\n---\n- [ ] 待办\n".utf8)
        let snapshot = try MarkdownSourceMapParser.parse(data)

        let overlay = try XCTUnwrap(
            MarkdownDraftSyntaxResolver.resolve(text: snapshot.text, snapshot: snapshot))

        XCTAssertEqual(
            overlay.opaqueRanges.map { decoded(snapshot.text, $0) },
            ["---\ntitle: 原题\n---\n"])
        XCTAssertEqual(overlay.taskMarkerRanges.map { decoded(snapshot.text, $0) }, ["[ ]"])
    }

    func testUneditedDraftResolutionMatchesSnapshotAndDraftPaths() throws {
        let data = Data("```\ncode\n```\n- [x] 完成\n".utf8)
        let snapshot = try MarkdownSourceMapParser.parse(data)

        let fromSnapshot = try XCTUnwrap(
            MarkdownDraftSyntaxResolver.resolve(text: snapshot.text, snapshot: snapshot))
        let fromDraft = try XCTUnwrap(
            MarkdownDraftSyntaxResolver.resolve(text: snapshot.text, snapshot: nil))

        XCTAssertEqual(fromSnapshot, fromDraft)
    }

    func testEditedDraftReparsesAndTracksTheDisplayedText() throws {
        let data = Data("%%\nsecret\n%%\n- [x] 完成\n".utf8)
        let snapshot = try MarkdownSourceMapParser.parse(data)
        let prefix = "新增一段\n"
        let edited = prefix + snapshot.text

        let overlay = try XCTUnwrap(
            MarkdownDraftSyntaxResolver.resolve(text: edited, snapshot: snapshot))

        XCTAssertEqual(overlay.opaqueRanges.map { decoded(edited, $0) }, ["%%\nsecret\n%%\n"])
        XCTAssertEqual(overlay.taskMarkerRanges.map { decoded(edited, $0) }, ["[x]"])
    }

    func testTaskMarkersInsideFencedAndOpaqueRegionsAreNotReported() throws {
        let text = "```\n- [ ] 非任务\n```\n%%\n- [ ] 藏起来的\n%%\n- [ ] 任务\n"

        let overlay = try XCTUnwrap(MarkdownDraftSyntaxResolver.resolve(text: text, snapshot: nil))

        XCTAssertEqual(overlay.opaqueRanges.map { decoded(text, $0) }, ["%%\n- [ ] 藏起来的\n%%\n"])
        XCTAssertEqual(overlay.taskMarkerRanges.map { decoded(text, $0) }, ["[ ]"])
    }

    func testOrderedAndUppercaseTaskMarkersAreRecognized() throws {
        let text = "1. [X] 第一\n2. [ ] 第二\n"

        let overlay = try XCTUnwrap(MarkdownDraftSyntaxResolver.resolve(text: text, snapshot: nil))

        XCTAssertEqual(overlay.taskMarkerRanges.map { decoded(text, $0) }, ["[X]", "[ ]"])
        XCTAssertTrue(overlay.opaqueRanges.isEmpty)
    }

    private func decoded(_ text: String, _ range: Range<Int>) -> String {
        String(decoding: Data(text.utf8).subdata(in: range), as: UTF8.self)
    }
}
