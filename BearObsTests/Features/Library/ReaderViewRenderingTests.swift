import SwiftUI
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

@MainActor
final class ReaderViewRenderingTests: XCTestCase {
    func testEveryReaderBlockRendersWithoutExecutingUnsafeContent() {
        let safeURL = URL(string: "https://example.com")
        let styled: [MarkdownRenderInline] = [
            .text("Plain "),
            .emphasis([.text("emphasis")]),
            .strong([.text(" strong")]),
            .strikethrough([.text(" removed")]),
            .code(" code"),
            .link(content: [.text(" link")], destination: safeURL),
            .link(content: [.text(" blocked")], destination: nil),
            .image(alternativeText: "diagram"),
            .lineBreak,
            .image(alternativeText: ""),
            .wikiLink(
                label: "Internal",
                target: "Folder/Note",
                resolution: .resolved(try! VaultPath(decodedRelativePath: "Folder/Note.md"))
            ),
            .wikiLink(label: "Missing", target: "Missing", resolution: .missing),
            .wikiLink(label: "Twin", target: "Twin", resolution: .ambiguous),
        ]
        let items = [
            MarkdownRenderListItem(task: .checked, blocks: [.paragraph([.text("Done")])]),
            MarkdownRenderListItem(task: .unchecked, blocks: [.paragraph([.text("Open")])]),
            MarkdownRenderListItem(task: nil, blocks: [.paragraph([.text("Item")])]),
        ]
        let blocks: [MarkdownRenderBlock] = [
            .heading(level: 1, content: styled),
            .heading(level: 2, content: [.text("Second")]),
            .heading(level: 3, content: [.text("Third")]),
            .heading(level: 5, content: [.text("Minor")]),
            .paragraph(styled),
            .quote([.paragraph([.text("Quote")])]),
            .unorderedList(items),
            .orderedList(start: 4, items: items),
            .codeBlock(language: "swift", code: "let value = 1"),
            .codeBlock(language: nil, code: "plain"),
            .thematicBreak,
            .fallback("<script>shown as text</script>"),
        ]
        let renderer = ImageRenderer(
            content: ScrollView {
                ReaderBlocksView(blocks: blocks)
                    .frame(width: 640, alignment: .leading)
                    .padding()
            }
        )

        XCTAssertNotNil(renderer.cgImage)
    }

    func testInternalRouteRoundTripsCanonicalPathAndRejectsForgedURLs() throws {
        let path = try VaultPath(decodedRelativePath: "空 格/100% Note.md")
        let url = ReaderInternalRoute.url(for: path)

        XCTAssertEqual(ReaderInternalRoute.path(from: url), path)
        for forged in [
            URL(string: "https://note.invalid?path=Secret.md")!,
            URL(string: "bearobs://other?path=Secret.md")!,
            URL(string: "bearobs://note?path=../Secret.md")!,
            URL(string: "bearobs://user:pass@note?path=Secret.md")!,
            URL(string: "bearobs://note?path=Secret.md&extra=1")!,
        ] {
            XCTAssertNil(ReaderInternalRoute.path(from: forged), forged.absoluteString)
        }
    }
}
