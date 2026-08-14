import Foundation
import Markdown
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownASTParserTests: XCTestCase {
    func testStandardMarkdownBuildsTypedASTWithSourceRanges() throws {
        let source = """
            ---
            title: Metadata
            ---
            # Heading

            Paragraph with *emphasis*, **strong**, ~~removed~~, [link](https://example.invalid), and `code`.

            > Quote

            1. Ordered

            - Unordered

            ```swift
            let value = 1
            ```

            ![Alt](image.png)

            | Name | Value |
            | --- | ---: |
            | one | 1 |
            """
        let data = Data(source.utf8)
        let frontmatter = try FrontmatterParser.parse(data)

        let result = MarkdownASTParser.parse(frontmatter)
        var probe = StandardNodeProbe()
        probe.visit(result.document)

        XCTAssertEqual(probe.headingLevels, [1])
        XCTAssertEqual(probe.headingLines, [1])
        XCTAssertEqual(probe.linkDestinations, ["https://example.invalid"])
        XCTAssertEqual(probe.imageSources, ["image.png"])
        XCTAssertEqual(probe.codeLanguages, ["swift"])
        XCTAssertEqual(probe.emphasisCount, 1)
        XCTAssertEqual(probe.strongCount, 1)
        XCTAssertEqual(probe.strikethroughCount, 1)
        XCTAssertEqual(probe.inlineCodeCount, 1)
        XCTAssertEqual(probe.blockQuoteCount, 1)
        XCTAssertEqual(probe.orderedListCount, 1)
        XCTAssertEqual(probe.unorderedListCount, 1)
        XCTAssertEqual(probe.tableCount, 1)
        XCTAssertEqual(result.bodyRange, frontmatter.bodyRange)
        XCTAssertEqual(frontmatter.originalData, data)
    }

    func testParserUsesFrontmatterBodyRangeInsteadOfGuessingBoundaries() throws {
        let data = Data("---\r\ntitle: '# Metadata'\r\n---\r\n# 正文\r\n".utf8)
        let frontmatter = try FrontmatterParser.parse(data)

        let result = MarkdownASTParser.parse(frontmatter)
        var probe = StandardNodeProbe()
        probe.visit(result.document)

        XCTAssertEqual(probe.headingLevels, [1])
        XCTAssertEqual(probe.headingLines, [1])
        XCTAssertEqual(result.bodyRange, frontmatter.bodyRange)
        XCTAssertEqual(frontmatter.bodyData, Data("# 正文\r\n".utf8))
        XCTAssertEqual(frontmatter.originalData, data)
    }

    func testBOMWithoutFrontmatterStillBuildsBodyRelativeAST() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("# 标题\r\n".utf8)
        let frontmatter = try FrontmatterParser.parse(data)

        let result = MarkdownASTParser.parse(frontmatter)
        var probe = StandardNodeProbe()
        probe.visit(result.document)

        XCTAssertEqual(frontmatter.state, .absent)
        XCTAssertEqual(result.bodyRange, data.startIndex..<data.endIndex)
        XCTAssertEqual(probe.headingLevels, [1])
        XCTAssertEqual(probe.headingLines, [1])
        XCTAssertEqual(frontmatter.originalData, data)
    }

    func testEmptyBodyProducesEmptyDocument() throws {
        let frontmatter = try FrontmatterParser.parse(Data("---\n---\n".utf8))

        let result = MarkdownASTParser.parse(frontmatter)

        XCTAssertEqual(result.document.childCount, 0)
        XCTAssertEqual(result.bodyRange, frontmatter.bodyRange)
    }

    func testRecoverableInvalidFrontmatterStillProducesBodyAST() throws {
        let data = Data("---\ntitle: [invalid\n---\n# Recoverable body\n".utf8)
        let frontmatter = try FrontmatterParser.parse(data)

        let result = MarkdownASTParser.parse(frontmatter)
        var probe = StandardNodeProbe()
        probe.visit(result.document)

        XCTAssertEqual(frontmatter.state, .invalid)
        XCTAssertEqual(frontmatter.diagnostic, .invalidYAML)
        XCTAssertEqual(probe.headingLevels, [1])
        XCTAssertEqual(result.bodyRange, frontmatter.bodyRange)
        XCTAssertEqual(frontmatter.originalData, data)
    }

    func testUnclosedFrontmatterUsesWholeDocumentFallback() throws {
        let data = Data("---\ntitle: Metadata\n# Recoverable body\n".utf8)
        let frontmatter = try FrontmatterParser.parse(data)

        let result = MarkdownASTParser.parse(frontmatter)
        var probe = StandardNodeProbe()
        probe.visit(result.document)

        XCTAssertEqual(frontmatter.diagnostic, .unclosed)
        XCTAssertEqual(result.bodyRange, data.startIndex..<data.endIndex)
        XCTAssertEqual(probe.headingLevels, [1])
        XCTAssertEqual(probe.headingLines, [3])
        XCTAssertEqual(frontmatter.originalData, data)
    }

    func testObsidianExtensionsRemainReadableStandardMarkdownText() throws {
        let data = Data("Visible #tag, [[Target]], and ![[Asset.png]].\n".utf8)
        let frontmatter = try FrontmatterParser.parse(data)

        let result = MarkdownASTParser.parse(frontmatter)
        var probe = StandardNodeProbe()
        probe.visit(result.document)

        XCTAssertEqual(
            probe.textFragments.joined(),
            "Visible #tag, [[Target]], and ![[Asset.png]]."
        )
        XCTAssertEqual(probe.linkDestinations, [])
        XCTAssertEqual(probe.imageSources, [])
        XCTAssertEqual(frontmatter.originalData, data)
    }
}

private struct StandardNodeProbe: MarkupWalker {
    var headingLevels: [Int] = []
    var headingLines: [Int] = []
    var linkDestinations: [String] = []
    var imageSources: [String] = []
    var codeLanguages: [String] = []
    var emphasisCount = 0
    var strongCount = 0
    var strikethroughCount = 0
    var inlineCodeCount = 0
    var blockQuoteCount = 0
    var orderedListCount = 0
    var unorderedListCount = 0
    var tableCount = 0
    var textFragments: [String] = []

    mutating func defaultVisit(_ markup: Markup) {
        switch markup {
        case let heading as Heading:
            headingLevels.append(heading.level)
            if let line = heading.range?.lowerBound.line {
                headingLines.append(line)
            }
        case let link as Link:
            if let destination = link.destination {
                linkDestinations.append(destination)
            }
        case let image as Image:
            if let source = image.source {
                imageSources.append(source)
            }
        case let codeBlock as CodeBlock:
            if let language = codeBlock.language {
                codeLanguages.append(language)
            }
        case is Emphasis:
            emphasisCount += 1
        case is Strong:
            strongCount += 1
        case is Strikethrough:
            strikethroughCount += 1
        case is InlineCode:
            inlineCodeCount += 1
        case is BlockQuote:
            blockQuoteCount += 1
        case is OrderedList:
            orderedListCount += 1
        case is UnorderedList:
            unorderedListCount += 1
        case is Table:
            tableCount += 1
        case let text as Text:
            textFragments.append(text.string)
        default:
            break
        }
        descendInto(markup)
    }
}
