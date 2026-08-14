import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsDomain
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownNoteParserTests: XCTestCase {
    func testFrontmatterTitleWinsOverATXHeadingAndFilename() throws {
        let data = Data(
            "---\ntitle: '  Metadata Title  '\n---\n# Body Title\n\nParagraph.\n".utf8
        )

        let note = try parse(data, path: "Fallback.md")

        XCTAssertEqual(note.title, "Metadata Title")
        XCTAssertEqual(note.preview, "Paragraph.")
        XCTAssertEqual(note.status, .complete)
        XCTAssertEqual(note.diagnostics, [])
    }

    func testFrontmatterTitleKeepsProseBeforeFirstBodyHeadingInPreview() throws {
        let data = Data(
            "---\ntitle: Metadata\n---\nIntro before section.\n\n# Section\n\nLater.\n".utf8
        )

        let note = try parse(data, path: "Fallback.md")

        XCTAssertEqual(note.title, "Metadata")
        XCTAssertEqual(note.preview, "Intro before section.")
    }

    func testOnlyFirstTopLevelATXH1CanOverrideFilename() throws {
        let source = """
            ---
            title: "   "
            ---
            Setext candidate
            ===

            ## H2

            > # Quoted

            # First *Real* [Title](https://example.invalid)

            # Second
            """

        let note = try parse(Data(source.utf8), path: "Fallback.md")

        XCTAssertEqual(note.title, "First Real Title")
    }

    func testFilenameStemIsFallbackAndPreviewUsesFirstSemanticParagraph() throws {
        let source = """
            Setext heading
            ===

            - list item

            Fallback prose.
            """

        let note = try parse(Data(source.utf8), path: "Folder/空 格%计划.MD")

        XCTAssertEqual(note.title, "空 格%计划")
        XCTAssertEqual(note.preview, "Fallback prose.")
    }

    func testEmptyVisibleATXHeadingFallsBackWithoutSkippingEarlierPreview() throws {
        let data = Data("Intro.\n\n# ![](x)\n\nLater.\n".utf8)

        let note = try parse(data, path: "Fallback.md")

        XCTAssertEqual(note.title, "Fallback")
        XCTAssertEqual(note.preview, "Intro.")
    }

    func testPreviewStripsStructureAndKeepsVisibleInlineContent() throws {
        let source = """
            # Heading

            ![ignored alt](image.png)

            ```text
            ignored code block
            ```

            <div data-value="ignored">ignored html</div>

            Paragraph with *emphasis*, **strong**, [visible link](https://example.invalid), `inline code`, [[Target|wiki alias]], and ![[asset.png]] a soft
            break.

            Later paragraph.
            """

        let note = try parse(Data(source.utf8), path: "Preview.md")

        XCTAssertEqual(
            note.preview,
            "Paragraph with emphasis, strong, visible link, inline code, wiki alias, and a soft break."
        )
    }

    func testTitleAndPreviewReplaceOnlyScannerConfirmedObsidianSyntax() throws {
        let source = #"""
            # `[[code literal]]` \[[escaped]] [[Real|Alias]] ![[hidden.png]]

            Preview `[[code literal]]` \[[escaped]] [[Real|Alias]] ![[hidden.png]].
            """#

        let note = try parse(Data(source.utf8), path: "Syntax.md")

        XCTAssertEqual(note.title, "[[code literal]] [[escaped]] Alias")
        XCTAssertEqual(note.preview, "Preview [[code literal]] [[escaped]] Alias .")
    }

    func testPreviewLimitCountsExtendedGraphemeClusters() throws {
        let source = Data("# Title\n\n中e\u{301}👨‍👩‍👧‍👦文末\n".utf8)
        let limits = MarkdownParseLimits(maximumPreviewCharacters: 4)

        let note = try parse(source, path: "Unicode.md", limits: limits)

        XCTAssertEqual(note.preview, "中é👨‍👩‍👧‍👦文")
        XCTAssertEqual(note.preview.count, 4)
    }

    func testTagsMergeInStableNFCCaseInsensitiveOrderWithoutDroppingOccurrences() throws {
        let source = """
            ---
            tags: [AI, "Café", project/mobile, AI, Ａ]
            ---
            # Tags

            #ai #CAFÉ #Project/Mobile #研发 #研发 #A
            """

        let note = try parse(Data(source.utf8), path: "Tags.md")

        XCTAssertEqual(
            note.tags.map(\.displayName),
            ["AI", "Café", "project/mobile", "Ａ", "研发", "A"]
        )
        XCTAssertEqual(
            note.tags.map(\.normalizedName),
            ["ai", "café", "project/mobile", "ａ", "研发", "a"]
        )
        XCTAssertEqual(
            note.syntax.inlineTags.map(\.name), ["ai", "CAFÉ", "Project/Mobile", "研发", "研发", "A"])
    }

    func testGoldenAggregationPreservesScannerOccurrences() throws {
        let data = try goldenData("Tags/inline-and-code.md")
        let frontmatter = try FrontmatterParser.parse(data)
        let ast = MarkdownASTParser.parse(frontmatter)
        let syntax = ObsidianSyntaxScanner.scan(ast)

        let note = try parse(data, path: "Tags/inline-and-code.md")

        XCTAssertEqual(note.title, "Inline tag fixture")
        XCTAssertEqual(note.tags.map(\.displayName), ["AI", "project/mobile", "研发/ios"])
        XCTAssertEqual(note.syntax, syntax)
        XCTAssertEqual(note.frontmatter.originalData, data)
    }

    func testRecoverableFrontmatterDiagnosticsKeepReadableTitleAndPreview() throws {
        let cases: [(String, MarkdownDiagnostic, String)] = [
            (
                "Frontmatter/malformed-yaml.md",
                .invalidFrontmatter,
                "The delimiters close, but the YAML does not."
            ),
            (
                "Frontmatter/unclosed.md",
                .unclosedFrontmatter,
                "The missing closing delimiter must not make this synthetic note unreadable."
            ),
        ]

        for (fixture, diagnostic, preview) in cases {
            let data = try goldenData(fixture)
            let note = try parse(data, path: fixture)

            XCTAssertEqual(note.title, "Recoverable body", fixture)
            XCTAssertEqual(note.preview, preview, fixture)
            XCTAssertEqual(note.diagnostics, [diagnostic], fixture)
            XCTAssertEqual(note.status, .degraded, fixture)
            XCTAssertEqual(note.frontmatter.originalData, data, fixture)
        }
    }

    func testFileLimitRunsBeforeUTF8ValidationAndInvalidUTF8IsTyped() throws {
        let tooLargeInvalid = Data(repeating: 0xFF, count: 5)

        XCTAssertThrowsError(
            try parse(
                tooLargeInvalid,
                path: "TooLarge.md",
                limits: MarkdownParseLimits(maximumNoteBytes: 4)
            )
        ) { error in
            XCTAssertEqual(
                error as? MarkdownParseError,
                .noteTooLarge(actual: 5, limit: 4)
            )
        }
        XCTAssertThrowsError(
            try parse(Data([0xFF, 0xFE]), path: "Invalid.md")
        ) { error in
            XCTAssertEqual(error as? MarkdownParseError, .invalidUTF8)
        }
        XCTAssertThrowsError(
            try parse(
                Data(repeating: 0xFF, count: 1_048_577),
                path: "DefaultTooLarge.md"
            )
        ) { error in
            XCTAssertEqual(
                error as? MarkdownParseError,
                .noteTooLarge(actual: 1_048_577, limit: 1_048_576)
            )
        }
        XCTAssertThrowsError(
            try parse(
                Data("text".utf8),
                path: "InvalidLimits.md",
                limits: MarkdownParseLimits(maximumNoteBytes: -1)
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownParseError, .invalidLimits)
        }
    }

    func testDefaultLimitAcceptsOneMiBGoldenFixture() throws {
        let data = try goldenData("Performance/large-note.md")

        let note = try parse(data, path: "Performance/large-note.md")

        XCTAssertEqual(data.count, 1_048_576)
        XCTAssertEqual(note.frontmatter.originalData.count, data.count)
        XCTAssertEqual(note.status, .complete)
    }

    func testFrontmatterLimitsAreRecoverableAndCheckedBeforeMetadataUse() throws {
        let data = Data("---\ntitle: Metadata\nextra: [one, two]\n---\n# Body\n\nReadable.\n".utf8)

        let byteLimited = try parse(
            data,
            path: "Limited.md",
            limits: MarkdownParseLimits(maximumFrontmatterBytes: 8)
        )
        let nodeLimited = try parse(
            data,
            path: "Limited.md",
            limits: MarkdownParseLimits(maximumYAMLNodes: 2)
        )

        for note in [byteLimited, nodeLimited] {
            XCTAssertEqual(note.title, "Body")
            XCTAssertEqual(note.preview, "Readable.")
            XCTAssertEqual(note.diagnostics, [.frontmatterResourceLimit])
            XCTAssertEqual(note.status, .degraded)
        }
    }

    func testYAMLComplexityPreflightRejectsDepthWidthAndAliases() throws {
        let deep = "---\nvalue: " + String(repeating: "[", count: 40) + "broken\n---\n# Body\n"
        let wide =
            "---\nvalue: [" + Array(repeating: "x", count: 20).joined(separator: ",")
            + "]\n---\n# Body\n"
        let aliases = "---\nbase: &base value\nitems: [*base, *base, *base]\n---\n# Body\n"
        let cases: [(String, MarkdownParseLimits)] = [
            (deep, MarkdownParseLimits(maximumYAMLDepth: 8)),
            (wide, MarkdownParseLimits(maximumYAMLNodes: 10)),
            (aliases, MarkdownParseLimits(maximumYAMLAliases: 2)),
        ]

        for (source, limits) in cases {
            let note = try parse(Data(source.utf8), path: "Limited.md", limits: limits)
            XCTAssertEqual(note.diagnostics, [.frontmatterResourceLimit])
            XCTAssertEqual(note.title, "Body")
        }
    }

    func testYAMLEventPreflightCatchesCompactDepthAndPlainHashKeys() throws {
        let compact =
            "---\nvalue:\n  " + String(repeating: "- ", count: 40)
            + "leaf\n---\n# Body\n"
        let plainHashKey =
            "---\nfoo#bar: " + String(repeating: "[", count: 40)
            + "leaf" + String(repeating: "]", count: 40) + "\n---\n# Body\n"

        for source in [compact, plainHashKey] {
            let note = try parse(
                Data(source.utf8),
                path: "Limited.md",
                limits: MarkdownParseLimits(maximumYAMLDepth: 8)
            )
            XCTAssertEqual(note.diagnostics, [.frontmatterResourceLimit])
            XCTAssertEqual(note.title, "Body")
        }
    }

    func testFrontmatterMergeKeysRemainCompatibleWithPreviousParser() throws {
        let data = Data(
            "---\ndefaults: &defaults\n  title: Merged\n  tags: [one, two]\n<<: *defaults\n---\nBody.\n"
                .utf8
        )

        let note = try parse(data, path: "Fallback.md")

        XCTAssertEqual(note.title, "Merged")
        XCTAssertEqual(note.tags.map(\.displayName), ["one", "two"])
        XCTAssertEqual(note.status, .complete)
    }

    func testFrontmatterTagAndSyntaxTokenBudgetsStopBeforeUnboundedResults() throws {
        let frontmatter = Data("---\ntags: [one, two, three]\n---\n# Body\n".utf8)
        let syntax = Data("# Body\n\n[[123456789]] #later\n".utf8)

        let tagLimited = try parse(
            frontmatter,
            path: "Tags.md",
            limits: MarkdownParseLimits(maximumFrontmatterTags: 2)
        )
        let tokenLimited = try parse(
            syntax,
            path: "Syntax.md",
            limits: MarkdownParseLimits(maximumSyntaxTokenBytes: 8)
        )

        XCTAssertEqual(tagLimited.tags, [])
        XCTAssertEqual(tagLimited.diagnostics, [.frontmatterResourceLimit])
        XCTAssertEqual(tokenLimited.syntax.wikiLinks, [])
        XCTAssertEqual(tokenLimited.syntax.inlineTags, [])
        XCTAssertEqual(tokenLimited.diagnostics, [.syntaxTokenLimit])
    }

    func testManySetextHeadingsDoNotChangeFilenameFallback() throws {
        let body = (0..<2_000).map { "Heading \($0)\n===" }.joined(separator: "\n\n")

        let note = try parse(Data(body.utf8), path: "Fallback.md")

        XCTAssertEqual(note.title, "Fallback")
    }

    func testSyntaxAndUniqueTagLimitsReturnBoundedDegradedResults() throws {
        let data = Data("# Title\n\n#one [[two]] ![[three]] #four\n".utf8)

        let syntaxLimited = try parse(
            data,
            path: "Limited.md",
            limits: MarkdownParseLimits(maximumSyntaxOccurrences: 3)
        )
        let tagsLimited = try parse(
            Data("# Title\n\n#one #two #three\n".utf8),
            path: "Limited.md",
            limits: MarkdownParseLimits(maximumUniqueTags: 2)
        )

        XCTAssertEqual(
            syntaxLimited.syntax.inlineTags.count
                + syntaxLimited.syntax.wikiLinks.count
                + syntaxLimited.syntax.embeds.count,
            3
        )
        XCTAssertEqual(syntaxLimited.diagnostics, [.syntaxOccurrenceLimit])
        XCTAssertEqual(syntaxLimited.status, .degraded)
        XCTAssertEqual(tagsLimited.tags.map(\.displayName), ["one", "two"])
        XCTAssertEqual(tagsLimited.diagnostics, [.uniqueTagLimit])
        XCTAssertEqual(tagsLimited.status, .degraded)
    }

    func testUnifiedParserPreservesAbsoluteRangesBOMCRLFAndOriginalData() throws {
        let data =
            Data([0xEF, 0xBB, 0xBF])
            + Data(
                "---\r\ntitle: Range\r\n---\r\n# Body\r\n\r\n#研发/ios [[真实链接|别名]] ![[附件/图 片.png]]\r\n"
                    .utf8
            )
        let snapshot = data
        let frontmatter = try FrontmatterParser.parse(data)
        let ast = MarkdownASTParser.parse(frontmatter)
        let syntax = ObsidianSyntaxScanner.scan(ast)

        let note = try parse(data, path: "Range.md")

        XCTAssertEqual(note.syntax, syntax)
        XCTAssertEqual(note.frontmatter.bodyRange, frontmatter.bodyRange)
        XCTAssertEqual(note.sourceInfo, MarkdownSourceInfo(hasUTF8BOM: true, lineEnding: .crlf))
        XCTAssertEqual(data, snapshot)
        for occurrence in note.syntax.inlineTags.map({ ($0.source, $0.sourceRange) })
            + note.syntax.wikiLinks.map({ ($0.source, $0.sourceRange) })
            + note.syntax.embeds.map({ ($0.source, $0.sourceRange) })
        {
            XCTAssertEqual(
                data.subdata(in: occurrence.1),
                Data(occurrence.0.utf8)
            )
        }
    }

    func testSourceInfoDistinguishesNoneLFCRLFAndMixed() throws {
        let cases: [(String, MarkdownLineEnding)] = [
            ("text", .none),
            ("one\ntwo\n", .lf),
            ("one\r\ntwo\r\n", .crlf),
            ("one\r\ntwo\n", .mixed),
        ]

        for (source, expected) in cases {
            let note = try parse(Data(source.utf8), path: "LineEnding.md")
            XCTAssertEqual(note.sourceInfo.lineEnding, expected, source.debugDescription)
        }
    }
}

extension MarkdownNoteParserTests {
    fileprivate func parse(
        _ data: Data,
        path: String,
        limits: MarkdownParseLimits = .default
    ) throws -> ParsedNote {
        try MarkdownNoteParser.parse(
            data,
            at: VaultPath(decodedRelativePath: path),
            limits: limits
        )
    }

    fileprivate func goldenData(_ relativePath: String) throws -> Data {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle(for: Self.self)
        #endif
        let fixture = try XCTUnwrap(
            bundle.url(forResource: "GoldenVault", withExtension: nil)
        )
        return try Data(
            contentsOf:
                fixture
                .appendingPathComponent("vault", isDirectory: true)
                .appendingPathComponent(relativePath)
        )
    }
}
