import SwiftUI
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

/// Mac-only inline editor rendering tests (REQ-004 §7 / ADR-010): this file is
/// excluded from the SPM `BearObsLibraryTests` target so the shared package
/// tests keep compiling for iOS, where the editing surface is compiled out.
/// The Xcode macOS unit test target keeps running it.
@MainActor
final class ReaderInlineEditorRenderingTests: XCTestCase {
    func testInlineEditorRendersInsideTheReaderContentArea() async throws {
        let path = try VaultPath(decodedRelativePath: "Inline.md")
        let document = EditorDocument(
            text: "# Inline\n\nEditable body.",
            contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        )
        let editor = EditorFeatureModel(
            path: path,
            source: EditorDataSource(
                load: { _ in document },
                save: { request in
                    EditorDocument(
                        text: request.text,
                        contentHash: document.contentHash,
                        sourceInfo: request.sourceInfo
                    )
                }
            )
        )
        await editor.load()

        let renderer = ImageRenderer(
            content: InlineMarkdownEditor(
                model: editor,
                finishEditing: {},
                retryReaderLoad: {},
                save: {}
            )
            .frame(width: 760, height: 520)
        )

        XCTAssertNotNil(renderer.cgImage)
    }

    func testInlineEditorKeepsLoadFailureInTheReaderContentArea() async throws {
        let path = try VaultPath(decodedRelativePath: "Unavailable.md")
        let editor = EditorFeatureModel(
            path: path,
            source: EditorDataSource(
                load: { _ in throw RenderFailure.expected },
                save: { _ in throw RenderFailure.expected }
            )
        )
        await editor.load()

        let renderer = ImageRenderer(
            content: InlineMarkdownEditor(
                model: editor,
                finishEditing: {},
                retryReaderLoad: {},
                save: {}
            )
            .frame(width: 760, height: 520)
        )

        XCTAssertNotNil(renderer.cgImage)
    }

    private enum RenderFailure: Error {
        case expected
    }
}
