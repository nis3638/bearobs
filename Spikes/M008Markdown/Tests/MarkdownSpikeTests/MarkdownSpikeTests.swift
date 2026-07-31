import Foundation
import XCTest

@testable import MarkdownSpike

final class MarkdownSpikeTests: XCTestCase {
    func testStandardMarkdownProducesASTAndHTML() throws {
        let source = """
            # Heading

            Paragraph with *emphasis*, [link](https://example.invalid), and `inlineCode`.

            - [x] task

            ```swift
            let value = 1
            ```

            ![Alt](image.png)
            """

        let result = try MarkdownSpike.analyze(Data(source.utf8))

        XCTAssertTrue(result.ast.nodeKinds.contains(.heading))
        XCTAssertTrue(result.ast.nodeKinds.contains(.paragraph))
        XCTAssertTrue(result.ast.nodeKinds.contains(.emphasis))
        XCTAssertTrue(result.ast.nodeKinds.contains(.link))
        XCTAssertTrue(result.ast.nodeKinds.contains(.inlineCode))
        XCTAssertTrue(result.ast.nodeKinds.contains(.codeBlock))
        XCTAssertTrue(result.ast.nodeKinds.contains(.image))
        XCTAssertTrue(result.ast.nodeKinds.contains(.unorderedList))
        XCTAssertEqual(result.ast.standardLinks, ["https://example.invalid"])
        XCTAssertEqual(result.ast.standardImages, ["image.png"])
        XCTAssertTrue(result.diagnosticHTML.contains("<h1>Heading</h1>"))
        XCTAssertTrue(result.diagnosticHTML.contains("href=\"https://example.invalid\""))
        XCTAssertTrue(result.diagnosticHTML.contains("src=\"image.png\""))
    }

    func testFrontmatterStringAndArrayTagsAreReadWithoutChangingBytes() throws {
        let cases: [(String, String, [String])] = [
            (
                "yaml-string-tags",
                "Synthetic String Tags",
                ["alpha", "project/mobile", "中文"]
            ),
            (
                "yaml-array-tags",
                "Synthetic Array Tags",
                ["beta", "project/ios", "研发"]
            ),
        ]

        for (caseID, title, tags) in cases {
            let data = try GoldenVault.data(caseID: caseID)
            let result = try MarkdownSpike.analyze(data)

            XCTAssertEqual(result.frontmatter.state, .valid, caseID)
            XCTAssertEqual(result.frontmatter.title, title, caseID)
            XCTAssertEqual(result.frontmatter.tags, tags, caseID)
            XCTAssertTrue(
                result.body.trimmingCharacters(in: .newlines).hasPrefix("# "),
                caseID
            )
            XCTAssertEqual(result.originalData, data, caseID)
            XCTAssertEqual(result.diagnostics, [], caseID)
        }
    }

    func testEmptyFrontmatterIsValid() throws {
        let source = "---\n---\n# Body\n"

        let result = try MarkdownSpike.analyze(Data(source.utf8))

        XCTAssertEqual(result.frontmatter.state, .valid)
        XCTAssertNil(result.frontmatter.title)
        XCTAssertEqual(result.frontmatter.tags, [])
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertTrue(result.body.contains("# Body"))
    }

    func testMalformedFrontmatterDegradesWithoutLosingReadableSource() throws {
        let cases: [(String, String)] = [
            ("invalid-frontmatter-unclosed", "frontmatter.unclosed"),
            ("invalid-frontmatter-yaml", "frontmatter.invalid-yaml"),
        ]

        for (caseID, diagnostic) in cases {
            let data = try GoldenVault.data(caseID: caseID)
            let result = try MarkdownSpike.analyze(data)

            XCTAssertEqual(result.frontmatter.state, .invalid, caseID)
            XCTAssertEqual(result.diagnostics, [diagnostic], caseID)
            XCTAssertTrue(result.source.contains("# Recoverable body"), caseID)
            XCTAssertTrue(result.diagnosticHTML.contains("Recoverable body"), caseID)
            XCTAssertEqual(result.originalData, data, caseID)
        }
    }

    func testInlineTagsExcludeCodeURLAndHTML() throws {
        let data = try GoldenVault.data(caseID: "inline-tags-and-code-exclusions")
        let result = try MarkdownSpike.analyze(data)

        XCTAssertEqual(result.inlineTags, ["AI", "project/mobile", "研发/ios"])
        XCTAssertEqual(result.wikiLinks, [])
        XCTAssertFalse(result.inlineTags.contains("ignored-inline"))
        XCTAssertFalse(result.inlineTags.contains("ignored-fence"))
        XCTAssertFalse(result.inlineTags.contains("ignored-url"))
        XCTAssertFalse(result.inlineTags.contains("ignored-html"))
        XCTAssertEqual(result.originalData, data)
    }

    func testStandardLinkTextIsVisibleButDestinationIsExcluded() throws {
        let source = """
            [Read #visible](#ignored-destination)
            [![#ignored-alt](image.png)](page)
            """

        let result = try MarkdownSpike.analyze(Data(source.utf8))

        XCTAssertEqual(result.inlineTags, ["visible"])
    }

    func testWikiLinksAndEmbedsAreExtractedWithoutPathResolution() throws {
        let linkResult = try MarkdownSpike.analyze(
            GoldenVault.data(caseID: "same-name-and-explicit-wiki-links")
        )
        XCTAssertEqual(
            linkResult.wikiLinks.map(\.target),
            ["Twin", "Area A/Twin", "Area B/Twin", "Unicode/空 格%计划"]
        )
        XCTAssertEqual(
            linkResult.wikiLinks.map(\.alias),
            [nil, nil, "Second twin", nil]
        )

        let imageResult = try MarkdownSpike.analyze(
            GoldenVault.data(caseID: "local-and-missing-images")
        )
        XCTAssertEqual(
            imageResult.embeds.map(\.target),
            ["Assets/local.svg", "Assets/missing.png"]
        )
        XCTAssertEqual(
            imageResult.embeds.map(\.source),
            ["![[Assets/local.svg]]", "![[Assets/missing.png]]"]
        )
        XCTAssertEqual(imageResult.ast.standardImages, ["../Assets/local.svg"])
    }

    func testWikiLinksAndEmbedsRespectBackslashEscapes() throws {
        let source = #"\[[Draft]] \![[hidden.png]] \\[[Live]] \\![[live.png]]"#

        let result = try MarkdownSpike.analyze(Data(source.utf8))

        XCTAssertEqual(result.wikiLinks.map(\.target), ["Live"])
        XCTAssertEqual(result.embeds.map(\.target), ["live.png"])
    }

    func testUnsupportedObsidianSyntaxRemainsReadable() throws {
        let data = try GoldenVault.data(
            caseID: "unsupported-obsidian-source-fallback"
        )
        let result = try MarkdownSpike.analyze(data)

        for (sourceToken, renderedToken) in [
            ("> [!NOTE]", "[!NOTE]"),
            ("==synthetic highlight==", "==synthetic highlight=="),
            ("%% synthetic comment %%", "%% synthetic comment %%"),
            ("^synthetic-block", "^synthetic-block"),
        ] {
            XCTAssertTrue(result.source.contains(sourceToken), sourceToken)
            XCTAssertTrue(result.diagnosticHTML.contains(renderedToken), renderedToken)
        }
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.originalData, data)
    }

    func testBOMAndLineEndingsAreReportedWithoutMutation() throws {
        let cases: [(String, Bool, MarkdownSpike.LineEnding)] = [
            ("utf8-bom-lf", true, .lf),
            ("utf8-no-bom-lf", false, .lf),
            ("utf8-no-bom-crlf", false, .crlf),
        ]

        for (caseID, hasBOM, lineEnding) in cases {
            let data = try GoldenVault.data(caseID: caseID)
            let result = try MarkdownSpike.analyze(data)
            XCTAssertEqual(result.encoding.utf8BOM, hasBOM, caseID)
            XCTAssertEqual(result.encoding.lineEnding, lineEnding, caseID)
            XCTAssertEqual(result.originalData, data, caseID)
        }
    }

    func testGoldenContractCasesRemainParseableWithinSpikeScope() throws {
        let contract = try GoldenVault.contract()

        XCTAssertEqual(contract.schemaVersion, 1)
        XCTAssertEqual(contract.parserCases.count, 13)
        for parserCase in contract.parserCases {
            XCTAssertFalse(parserCase.features.isEmpty, parserCase.id)
            let data = try GoldenVault.data(parserCase.path)
            let result = try MarkdownSpike.analyze(data)
            XCTAssertEqual(result.originalData, data, parserCase.id)
            assertContract(parserCase.expected, matches: result, caseID: parserCase.id)
        }
    }

    func testUnicodeAndCRLFDoNotBreakCodeExclusions() throws {
        let source = """
            # 标题\r\n\r\nVisible #研发/ios and `#隐藏 [[代码链接]]`.\r\n\r\n```swift\r\n#围栏 [[围栏链接]]\r\n```\r\n\r\n[[真实链接|别名]]\r\n
            """
        let result = try MarkdownSpike.analyze(Data(source.utf8))

        XCTAssertEqual(result.inlineTags, ["研发/ios"])
        XCTAssertEqual(result.wikiLinks.map(\.target), ["真实链接"])
        XCTAssertEqual(result.wikiLinks.map(\.alias), ["别名"])
    }

    func testInvalidUTF8FailsExplicitly() {
        XCTAssertThrowsError(try MarkdownSpike.analyze(Data([0xFF, 0xFE]))) { error in
            XCTAssertEqual(error as? MarkdownSpike.Error, .invalidUTF8)
        }
    }

    private func assertContract(
        _ expected: GoldenVault.Expected,
        matches result: MarkdownSpike.Analysis,
        caseID: String
    ) {
        if let frontmatter = expected.frontmatter {
            XCTAssertEqual(result.frontmatter.state.contractValue, frontmatter.state, caseID)
            if let tags = frontmatter.tags {
                XCTAssertEqual(result.frontmatter.tags, tags, caseID)
            }
            if let diagnostic = frontmatter.diagnostic {
                XCTAssertEqual(result.diagnostics, [diagnostic], caseID)
            }
        }
        if let inlineTags = expected.inlineTags {
            XCTAssertEqual(result.inlineTags, inlineTags, caseID)
        }
        for token in expected.excludedSourceTokens ?? [] {
            if token.hasPrefix("#") {
                XCTAssertFalse(result.inlineTags.contains(String(token.dropFirst())), caseID)
            } else {
                XCTAssertFalse(result.wikiLinks.map(\.source).contains(token), caseID)
            }
        }
        if let links = expected.links {
            XCTAssertEqual(result.wikiLinks.map(\.source), links.map(\.source), caseID)
            XCTAssertEqual(result.wikiLinks.map(\.target), links.map(\.target), caseID)
            XCTAssertEqual(result.wikiLinks.map(\.alias), links.map(\.alias), caseID)
        }
        if let attachments = expected.attachments {
            let embeds = attachments.filter { $0.syntax == "obsidian-embed" }
            let images = attachments.filter { $0.syntax == "markdown-image" }
            XCTAssertEqual(result.embeds.map(\.source), embeds.map(\.source), caseID)
            XCTAssertEqual(result.embeds.map(\.target), embeds.map(\.target), caseID)
            XCTAssertEqual(result.ast.standardImages, images.map(\.target), caseID)
        }
        if let encoding = expected.encoding {
            XCTAssertEqual(result.encoding.utf8BOM, encoding.utf8BOM, caseID)
            XCTAssertEqual(result.encoding.lineEnding.contractValue, encoding.lineEnding, caseID)
        }
        if let fallback = expected.fallback {
            for token in fallback.preservedSource {
                XCTAssertTrue(result.source.contains(token), "\(caseID): \(token)")
            }
            XCTAssertEqual(result.diagnostics, fallback.diagnostics, caseID)
        }
    }
}

extension MarkdownSpike.FrontmatterState {
    fileprivate var contractValue: String {
        switch self {
        case .absent: "absent"
        case .valid: "valid"
        case .invalid: "invalid"
        }
    }
}

extension MarkdownSpike.LineEnding {
    fileprivate var contractValue: String {
        switch self {
        case .none: "none"
        case .lf: "lf"
        case .crlf: "crlf"
        case .mixed: "mixed"
        }
    }
}
