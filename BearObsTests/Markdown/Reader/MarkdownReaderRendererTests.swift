import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownReaderRendererTests: XCTestCase {
    func testRendersRequiredStandardMarkdownIntoClosedValues() throws {
        let source = """
            # Heading

            Plain *emphasis* **strong** ~~removed~~ `code` [safe](https://example.com/path).

            > Quoted

            - [x] Done
            - Open

            3. Three

            ```swift
            let value = 1
            ```
            """
        let document = try render(source)

        XCTAssertEqual(document.blocks.count, 6)
        XCTAssertEqual(document.blocks[0], .heading(level: 1, content: [.text("Heading")]))
        guard case .paragraph(let inline) = document.blocks[1] else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertTrue(inline.contains(.emphasis([.text("emphasis")])))
        XCTAssertTrue(inline.contains(.strong([.text("strong")])))
        XCTAssertTrue(inline.contains(.strikethrough([.text("removed")])))
        XCTAssertTrue(inline.contains(.code("code")))
        XCTAssertTrue(
            inline.contains(
                .link(
                    content: [.text("safe")],
                    destination: URL(string: "https://example.com/path")
                )
            )
        )
        XCTAssertEqual(document.blocks[2], .quote([.paragraph([.text("Quoted")])]))
        XCTAssertEqual(
            document.blocks[3],
            .unorderedList([
                MarkdownRenderListItem(task: .checked, blocks: [.paragraph([.text("Done")])]),
                MarkdownRenderListItem(task: nil, blocks: [.paragraph([.text("Open")])]),
            ])
        )
        XCTAssertEqual(
            document.blocks[4],
            .orderedList(
                start: 3,
                items: [MarkdownRenderListItem(task: nil, blocks: [.paragraph([.text("Three")])])]
            )
        )
        XCTAssertEqual(document.blocks[5], .codeBlock(language: "swift", code: "let value = 1\n"))
    }

    func testUnsafeLinksAndRawHTMLRemainReadableButCannotBecomeActions() throws {
        let source = """
            [unsafe](javascript:alert(1)) and [credential](https://user:secret@example.com)

            <script>alert('visible')</script>
            """
        let document = try render(source)

        guard case .paragraph(let inline) = document.blocks[0] else {
            return XCTFail("Expected paragraph")
        }
        XCTAssertTrue(inline.contains(.link(content: [.text("unsafe")], destination: nil)))
        XCTAssertTrue(inline.contains(.link(content: [.text("credential")], destination: nil)))
        XCTAssertEqual(document.blocks[1], .fallback("<script>alert('visible')</script>"))
    }

    func testObsidianSyntaxIsPreservedAsReadableTextUntilLinkResolution() throws {
        let document = try render("Read [[Target|Alias]] and ![[asset.png]].")

        XCTAssertEqual(
            document.blocks,
            [.paragraph([.text("Read [[Target|Alias]] and ![[asset.png]].")])]
        )
    }

    func testResolvedMissingAndAmbiguousWikiLinksMapByExactOccurrence() throws {
        let source = "Read [[Target|Alias]], [[Missing]], and [[Twin]]."
        let path = try VaultPath(decodedRelativePath: "Reader.md")
        let note = try MarkdownNoteParser.parse(Data(source.utf8), at: path)
        let destination = try VaultPath(decodedRelativePath: "Folder/Target.md")
        let links = note.syntax.wikiLinks

        let document = MarkdownReaderRenderer.render(
            note,
            wikiLinks: [
                .init(sourceRange: links[0].sourceRange, resolution: .resolved(destination)),
                .init(sourceRange: links[1].sourceRange, resolution: .missing),
                .init(sourceRange: links[2].sourceRange, resolution: .ambiguous),
            ]
        )

        XCTAssertEqual(
            document.blocks,
            [
                .paragraph([
                    .text("Read "),
                    .wikiLink(label: "Alias", target: "Target", resolution: .resolved(destination)),
                    .text(", "),
                    .wikiLink(label: "Missing", target: "Missing", resolution: .missing),
                    .text(", and "),
                    .wikiLink(label: "Twin", target: "Twin", resolution: .ambiguous),
                    .text("."),
                ])
            ]
        )
    }

    func testPartialResolutionCannotAttachToAnEarlierIdenticalOccurrence() throws {
        let source = "[[Target]] then [[Target]]"
        let note = try MarkdownNoteParser.parse(
            Data(source.utf8),
            at: VaultPath(decodedRelativePath: "Reader.md")
        )
        let target = try VaultPath(decodedRelativePath: "Target.md")

        let document = MarkdownReaderRenderer.render(
            note,
            wikiLinks: [
                .init(
                    sourceRange: note.syntax.wikiLinks[1].sourceRange,
                    resolution: .resolved(target)
                )
            ]
        )

        XCTAssertEqual(
            document.blocks,
            [
                .paragraph([
                    .text("[[Target]] then "),
                    .wikiLink(label: "Target", target: "Target", resolution: .resolved(target)),
                ])
            ]
        )
    }

    private func render(_ source: String) throws -> MarkdownRenderDocument {
        let path = try VaultPath(decodedRelativePath: "Reader.md")
        let note = try MarkdownNoteParser.parse(Data(source.utf8), at: path)
        return MarkdownReaderRenderer.render(note)
    }
}
