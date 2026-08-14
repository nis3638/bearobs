import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class ObsidianSyntaxScannerTests: XCTestCase {
    func testGoldenInlineTagsExcludeCodeURLAndHTMLAttributes() throws {
        let data = try goldenData("Tags/inline-and-code.md")

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["AI", "project/mobile", "研发/ios"])
        XCTAssertEqual(
            result.inlineTags.map { decodedSource(data, at: $0.sourceRange) },
            [
                "#AI", "#project/mobile", "#研发/ios",
            ])
        XCTAssertEqual(result.wikiLinks, [])
        XCTAssertEqual(result.embeds, [])
    }

    func testStandardLinkTextIsVisibleButDestinationAndImageAreExcluded() throws {
        let source =
            "[Read **#visible**](https://example.invalid/p#ignored-destination) "
            + "[![#ignored-alt](image-#ignored-image.png)](page) "
            + "<https://example.invalid/#ignored-autolink>\n"
        let data = Data(source.utf8)

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["visible"])
        XCTAssertEqual(
            result.inlineTags.map { decodedSource(data, at: $0.sourceRange) }, ["#visible"])
        XCTAssertEqual(result.wikiLinks, [])
        XCTAssertEqual(result.embeds, [])
    }

    func testInlineHTMLAttributesAreExcludedWhileVisibleTextIsScanned() throws {
        let data = Data(
            "<span data-topic=\"#ignored\" data-link=\"[[Ignored]]\">"
                .appending("body #visible</span>\n").utf8
        )

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["visible"])
        XCTAssertEqual(result.wikiLinks, [])
        XCTAssertEqual(result.embeds, [])
    }

    func testGoldenWikiLinksPreserveSourceTargetAliasAndByteRanges() throws {
        let data = try goldenData("Links/Home.md")

        let result = try scan(data)

        XCTAssertEqual(
            result.wikiLinks.map(\.source),
            [
                "[[Twin]]",
                "[[Area A/Twin]]",
                "[[Area B/Twin|Second twin]]",
                "[[Unicode/空 格%计划]]",
            ])
        XCTAssertEqual(
            result.wikiLinks.map(\.target),
            [
                "Twin", "Area A/Twin", "Area B/Twin", "Unicode/空 格%计划",
            ])
        XCTAssertEqual(result.wikiLinks.map(\.alias), [nil, nil, "Second twin", nil])
        XCTAssertEqual(
            result.wikiLinks.map { decodedSource(data, at: $0.sourceRange) },
            result.wikiLinks.map(\.source)
        )
        XCTAssertEqual(result.embeds, [])
    }

    func testGoldenEmbedsDoNotMisclassifyStandardMarkdownImages() throws {
        let data = try goldenData("Attachments/image-note.md")

        let result = try scan(data)

        XCTAssertEqual(
            result.embeds.map(\.source),
            [
                "![[Assets/local.svg]]", "![[Assets/missing.png]]",
            ])
        XCTAssertEqual(
            result.embeds.map(\.target),
            [
                "Assets/local.svg", "Assets/missing.png",
            ])
        XCTAssertEqual(
            result.embeds.map { decodedSource(data, at: $0.sourceRange) },
            result.embeds.map(\.source)
        )
        XCTAssertEqual(result.wikiLinks, [])
    }

    func testWikiLinksAndEmbedsRespectOddAndEvenBackslashEscapes() throws {
        let data = Data(
            ##"\#hidden \\#live \[[Draft]] \![[hidden.png]] \\[[Live]] \\![[live.png]]"##.utf8
        )

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["live"])
        XCTAssertEqual(result.wikiLinks.map(\.target), ["Live"])
        XCTAssertEqual(result.embeds.map(\.target), ["live.png"])
        XCTAssertEqual(result.inlineTags.map { decodedSource(data, at: $0.sourceRange) }, ["#live"])
        XCTAssertEqual(
            result.wikiLinks.map { decodedSource(data, at: $0.sourceRange) }, ["[[Live]]"])
        XCTAssertEqual(
            result.embeds.map { decodedSource(data, at: $0.sourceRange) }, ["![[live.png]]"])
    }

    func testFrontmatterBoundaryCRLFAndUnicodeMapBackToOriginalBytes() throws {
        let source =
            "---\r\ntags: '#metadata'\r\n---\r\n"
            + "Visible #研发/ios and [[真实链接|别名]].\r\n"
            + "`#隐藏 [[代码链接]]`\r\n"
        let data = Data(source.utf8)

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["研发/ios"])
        XCTAssertEqual(result.wikiLinks.map(\.target), ["真实链接"])
        XCTAssertEqual(result.wikiLinks.map(\.alias), ["别名"])
        XCTAssertEqual(
            result.inlineTags.map { decodedSource(data, at: $0.sourceRange) }, ["#研发/ios"])
        XCTAssertEqual(
            result.wikiLinks.map { decodedSource(data, at: $0.sourceRange) }, ["[[真实链接|别名]]"])
    }

    func testBOMOnFirstBodyLineKeepsAbsoluteByteRangesCorrect() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("#visible [[目标]]\n".utf8)

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["visible"])
        XCTAssertEqual(result.wikiLinks.map(\.target), ["目标"])
        XCTAssertEqual(result.inlineTags.map(\.sourceRange.lowerBound), [3])
        XCTAssertEqual(
            result.inlineTags.map { decodedSource(data, at: $0.sourceRange) }, ["#visible"])
        XCTAssertEqual(result.wikiLinks.map { decodedSource(data, at: $0.sourceRange) }, ["[[目标]]"])
    }

    func testEmptyTokensAreIgnoredAndDuplicateTagsKeepEveryOccurrence() throws {
        let data = Data("#same #same [[]] [[ |alias]] ![[]] #not.valid\n".utf8)

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["same", "same", "not"])
        XCTAssertEqual(
            result.inlineTags.map { decodedSource(data, at: $0.sourceRange) },
            [
                "#same", "#same", "#not",
            ])
        XCTAssertEqual(result.wikiLinks, [])
        XCTAssertEqual(result.embeds, [])
    }

    func testIndentedAndTildeCodeBlocksAreExcluded() throws {
        let source = """
            Outside #live [[Live]] ![[live.png]]

                #indented [[Indented]] ![[indented.png]]

            ~~~text
            #tilde [[Tilde]] ![[tilde.png]]
            ~~~
            """

        let result = try scan(Data(source.utf8))

        XCTAssertEqual(result.inlineTags.map(\.name), ["live"])
        XCTAssertEqual(result.wikiLinks.map(\.target), ["Live"])
        XCTAssertEqual(result.embeds.map(\.target), ["live.png"])
    }

    func testTagGrammarRequiresABoundaryAndConsumesOnlySupportedNames() throws {
        let data = Data(
            ##"#A #project/mobile #研发_ios #with-dash word#bad https://x/#fragment # #-bad #/bad \#escaped [[Note#Heading|#Alias]] ![[image.png#crop]]"##
                .utf8
        )

        let result = try scan(data)

        XCTAssertEqual(
            result.inlineTags.map(\.name), ["A", "project/mobile", "研发_ios", "with-dash"])
        XCTAssertEqual(result.wikiLinks.map(\.target), ["Note#Heading"])
        XCTAssertEqual(result.wikiLinks.map(\.alias), ["#Alias"])
        XCTAssertEqual(result.embeds.map(\.target), ["image.png#crop"])
    }

    func testUnclosedAndMultilineBracketTokensStayReadableWithoutQuadraticSearch() throws {
        let unclosed = String(repeating: "[", count: 65_536)
        let data = Data("[[first\nsecond]] #visible \(unclosed)".utf8)

        let result = try scan(data)

        XCTAssertEqual(result.inlineTags.map(\.name), ["visible"])
        XCTAssertEqual(result.wikiLinks, [])
        XCTAssertEqual(result.embeds, [])
    }

    func testUnclosedFrontmatterUsesParserFallbackInsteadOfBeingGuessedAgain() throws {
        let data = Data("---\ntitle: [[Metadata]]\nbody #fallback\n".utf8)
        let frontmatter = try FrontmatterParser.parse(data)
        let ast = MarkdownASTParser.parse(frontmatter)

        let result = ObsidianSyntaxScanner.scan(ast)

        XCTAssertEqual(frontmatter.diagnostic, .unclosed)
        XCTAssertEqual(result.inlineTags.map(\.name), ["fallback"])
        XCTAssertEqual(result.wikiLinks.map(\.target), ["Metadata"])
        XCTAssertEqual(frontmatter.originalData, data)
    }
}

extension ObsidianSyntaxScannerTests {
    fileprivate func scan(_ data: Data) throws -> ObsidianSyntaxScanResult {
        let frontmatter = try FrontmatterParser.parse(data)
        let ast = MarkdownASTParser.parse(frontmatter)
        return ObsidianSyntaxScanner.scan(ast)
    }

    fileprivate func decodedSource(_ data: Data, at range: Range<Int>) -> String {
        String(decoding: data.subdata(in: range), as: UTF8.self)
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
