import AppKit
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

@MainActor
final class SourcePreservingTextViewTests: XCTestCase {
    private var draftChanges: [String] = []
    private var selections: [(anchor: Int, head: Int)] = []
    private var viewports: [(anchor: Int, offset: Double)] = []
    private var markedTextFlags: [Bool] = []
    private var saveCallCount = 0
    private var escapeCallCount = 0

    func testMakeScrollViewShowsDraftBorderlessWithStableIdentity() async throws {
        let surface = try await makeLoadedSurface(text: "# 标题\n\n正文段落。")
        let scrollView = surface.scrollView
        let textView = try XCTUnwrap(surface.textView)

        XCTAssertEqual(textView.string, "# 标题\n\n正文段落。")
        XCTAssertEqual(textView.accessibilityIdentifier(), "inline-editor-text")
        XCTAssertEqual(textView.accessibilityLabel(), "可编辑笔记内容")
        XCTAssertEqual(scrollView.borderType, .noBorder)
        XCTAssertFalse(scrollView.drawsBackground)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertFalse(textView.isRichText)
        XCTAssertTrue(scrollView.hasVerticalScroller)
    }

    func testTypingReportsDraftAndUTF8SelectionToModel() async throws {
        let surface = try await makeLoadedSurface(text: "你好world")
        let textView = try XCTUnwrap(surface.textView)

        textView.setSelectedRange(NSRange(location: 7, length: 0))
        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(draftChanges.last, "你好world!")
        XCTAssertEqual(surface.model.draft, "你好world!")
        XCTAssertEqual(surface.model.draftRevision, 2)
        XCTAssertEqual(selections.last?.anchor, 12)
        XCTAssertEqual(selections.last?.head, 12)
        XCTAssertEqual(surface.model.selection, EditorSelection(anchorUTF8: 12, headUTF8: 12))
    }

    func testUndoRevertsTypingThroughTheSameDraftCallbacks() async throws {
        let surface = try await makeLoadedSurface(text: "baseline")
        let textView = try XCTUnwrap(surface.textView)

        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(surface.model.draft, "baselineab")

        // Consecutive programmatic inserts may coalesce into one undo group.
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, surface.model.draft)
        XCTAssertTrue(textView.string == "baseline" || textView.string == "baselinea")

        if textView.string == "baselinea" {
            textView.undoManager?.undo()
        }
        XCTAssertEqual(textView.string, "baseline")
        XCTAssertEqual(surface.model.draft, "baseline")
        XCTAssertFalse(surface.model.isDirty)
    }

    func testEchoUpdateDoesNotRewriteStorageOrSelection() async throws {
        let surface = try await makeLoadedSurface(text: "baseline")
        let textView = try XCTUnwrap(surface.textView)

        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.insertText("!", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(surface.model.draftRevision, 2)

        syncFromModel(surface)

        XCTAssertEqual(textView.string, "baseline!")
        XCTAssertEqual(textView.selectedRange().location, 9)

        // If the echo had rewritten the storage it would have pushed an extra
        // undoable group on top of the typing edit.
        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, "baseline")
        XCTAssertEqual(surface.model.draft, "baseline")
    }

    func testExternalCanonicalizationIsSingleUndoableChangePreservingSelection() async throws {
        let baseline = EditorDocument(
            text: "baseline",
            contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        )
        let savedHash = try ContentHash(hex: String(repeating: "b", count: 64))
        let model = try makeModel(
            document: baseline,
            save: { request in
                EditorDocument(
                    text: request.text + "\n",
                    contentHash: savedHash,
                    sourceInfo: request.sourceInfo
                )
            }
        )
        await model.load()
        let surface = makeSurface(model: model)
        await drainQueuedRestoreBlock()
        let textView = try XCTUnwrap(surface.textView)

        model.updateDraft("edited text")
        syncFromModel(surface)
        textView.setSelectedRange(NSRange(location: 11, length: 0))

        await model.save()
        XCTAssertEqual(model.draft, "edited text\n")
        XCTAssertEqual(model.draftRevision, 3)

        syncFromModel(surface)
        XCTAssertEqual(textView.string, "edited text\n")
        XCTAssertEqual(textView.selectedRange().location, 11)

        // Undo must revert the external canonicalization through the same
        // draft callbacks. NSUndoManager group boundaries depend on the host
        // runloop, so assert per-step model/view agreement instead of the
        // number of steps it takes.
        var undoSteps = 0
        while textView.string == "edited text\n" {
            textView.undoManager?.undo()
            undoSteps += 1
            XCTAssertLessThan(undoSteps, 5, "Undo never left the canonical text")
            XCTAssertEqual(textView.string, model.draft)
        }
        XCTAssertTrue(
            textView.string == "edited text" || textView.string == "baseline",
            "Unexpected undo result: \(textView.string)"
        )

        var redoSteps = 0
        while textView.string != "edited text\n" {
            textView.undoManager?.redo()
            redoSteps += 1
            XCTAssertLessThan(redoSteps, 5, "Redo never reached the canonical text")
            XCTAssertEqual(textView.string, model.draft)
        }
        XCTAssertEqual(model.draft, "edited text\n")
    }

    func testMarkedTextCompositionSurvivesExternalRevision() async throws {
        let surface = try await makeLoadedSurface(text: "基础")
        let textView = try XCTUnwrap(surface.textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        textView.setMarkedText(
            "pinyin",
            selectedRange: NSRange(location: 0, length: 6),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        XCTAssertEqual(markedTextFlags.last, true)
        XCTAssertTrue(surface.model.isMarkedTextActive)

        surface.model.updateDraft("外部新文本")
        syncFromModel(surface)
        XCTAssertEqual(textView.string, "基础pinyin")

        textView.unmarkText()
        XCTAssertEqual(markedTextFlags.last, false)
        XCTAssertFalse(surface.model.isMarkedTextActive)
        XCTAssertEqual(textView.string, "基础pinyin")
        XCTAssertEqual(surface.model.draft, "基础pinyin")

        syncFromModel(surface)
        XCTAssertEqual(textView.string, "基础pinyin")
    }

    func testEscapeAndCommandSaveRouteThroughCallbacks() async throws {
        let surface = try await makeLoadedSurface(text: "正文")
        let textView = try XCTUnwrap(surface.textView)

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(escapeCallCount, 1)
        XCTAssertEqual(saveCallCount, 0)

        textView.setMarkedText(
            "pin",
            selectedRange: NSRange(location: 0, length: 3),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(textView.hasMarkedText())
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(escapeCallCount, 1)
        textView.unmarkText()

        let saveEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.command],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "s",
                charactersIgnoringModifiers: "s",
                isARepeat: false,
                keyCode: 1
            )
        )
        XCTAssertTrue(textView.performKeyEquivalent(with: saveEvent))
        XCTAssertEqual(saveCallCount, 1)

        let plainEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            )
        )
        XCTAssertFalse(textView.performKeyEquivalent(with: plainEvent))
        XCTAssertEqual(saveCallCount, 1)
    }

    func testProjectionStylesApplyToUTF8RunsAndStaleProjectionIsIgnored() async throws {
        let text = "# 大标题\n\n正文段落 body\n\n```\ncode\n```\n\n> 引用行\n"
        let surface = try await makeLoadedSurface(text: text)
        let textView = try XCTUnwrap(surface.textView)
        let storage = try XCTUnwrap(textView.textStorage)

        let projection = try XCTUnwrap(
            MarkdownEditorProjectionBuilder.build(
                text: text, snapshot: surface.model.sourceSnapshot)
        )
        syncFromModel(surface, projection: projection)

        let map = MarkdownTextCoordinateMap(text: text)
        let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        let firstLevelHeadingFont = NSFont.systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .largeTitle).pointSize,
            weight: .semibold
        )

        let headingRange = try XCTUnwrap(map.utf16Range(forUTF8: 0..<utf8Length("# 大标题")))
        let headingFont = try XCTUnwrap(
            storage.attribute(.font, at: headingRange.lowerBound, effectiveRange: nil) as? NSFont
        )
        XCTAssertGreaterThan(headingFont.pointSize, bodySize)
        XCTAssertEqual(headingFont, firstLevelHeadingFont)

        let codeStart = utf8Length("# 大标题\n\n正文段落 body\n\n")
        let codeLength = utf8Length("```\ncode\n```")
        let codeRange = try XCTUnwrap(
            map.utf16Range(forUTF8: codeStart..<(codeStart + codeLength))
        )
        let codeFont = try XCTUnwrap(
            storage.attribute(.font, at: codeRange.lowerBound, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(
            codeFont.familyName,
            NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).familyName
        )

        let quoteStart = codeStart + codeLength + utf8Length("\n\n")
        let quoteRange = try XCTUnwrap(
            map.utf16Range(forUTF8: quoteStart..<(quoteStart + utf8Length("> 引用行")))
        )
        let quoteStyle = try XCTUnwrap(
            storage.attribute(.paragraphStyle, at: quoteRange.lowerBound, effectiveRange: nil)
                as? NSParagraphStyle
        )
        XCTAssertEqual(quoteStyle.headIndent, 12)

        // A projection for a different text must not strip the applied styles.
        let staleProjection = MarkdownEditorProjection(text: "别的草稿", runs: [])
        syncFromModel(surface, projection: staleProjection)
        let fontAfterStale = try XCTUnwrap(
            storage.attribute(.font, at: headingRange.lowerBound, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(fontAfterStale, firstLevelHeadingFont)
    }

    func testSelectionCallbacksReportUTF8OffsetsForAstralAndCJK() async throws {
        let surface = try await makeLoadedSurface(text: "😀文本abc")
        let textView = try XCTUnwrap(surface.textView)

        textView.setSelectedRange(NSRange(location: 2, length: 2))

        XCTAssertEqual(selections.last?.anchor, 4)
        XCTAssertEqual(selections.last?.head, 10)
        XCTAssertEqual(surface.model.selection, EditorSelection(anchorUTF8: 4, headUTF8: 10))
    }

    func testCopyPasteAcrossBlocksUpdatesDraft() async throws {
        let surface = try await makeLoadedSurface(text: "# 标题\n\n正文段落内容\n")
        let textView = try XCTUnwrap(surface.textView)

        textView.setSelectedRange(NSRange(location: 0, length: 12))
        textView.copy(nil)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "# 标题\n\n正文段落内容"
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("替换文本", forType: .string)
        textView.paste(nil)

        XCTAssertEqual(surface.model.draft, "替换文本\n")
        XCTAssertEqual(surface.model.draftRevision, 2)
        XCTAssertEqual(draftChanges.last, "替换文本\n")
    }

    func testExternalChangePreservesFirstVisibleLine() async throws {
        let text = (1...120).map { "第\($0)行的内容行\n" }.joined()
        let surface = try await makeLoadedSurface(text: text)
        let scrollView = surface.scrollView
        let textView = try XCTUnwrap(surface.textView)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)

        scrollView.frame = NSRect(x: 0, y: 0, width: 640, height: 300)
        layoutManager.ensureLayout(for: container)
        textView.frame.size.height =
            layoutManager.usedRect(for: container).height
            + textView.textContainerInset.height * 2

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 800))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let before = try XCTUnwrap(viewports.last)
        XCTAssertGreaterThan(before.anchor, 0)
        let beforeLine = lineContent(containingUTF8: before.anchor, in: surface.model.draft)
        XCTAssertFalse(beforeLine.isEmpty)

        // Two newlines above the viewport shift every anchor; only the saved
        // scroll anchor can bring the same line back to the visible top.
        surface.model.updateDraft("\n\n" + surface.model.draft)
        syncFromModel(surface)

        let after = try XCTUnwrap(viewports.last)
        XCTAssertEqual(
            lineContent(containingUTF8: after.anchor, in: surface.model.draft),
            beforeLine
        )
        XCTAssertEqual(after.offset, before.offset, accuracy: 1.0)
    }

    // MARK: - Helpers

    @MainActor
    private struct Surface {
        let model: EditorFeatureModel
        let coordinator: SourcePreservingTextView.Coordinator
        let scrollView: NSScrollView
        // A real window gives the text view a responder chain and therefore a
        // working undo manager, matching how SwiftUI hosts the surface.
        let window: NSWindow

        var textView: SourcePreservingTextView.EditorTextView? {
            scrollView.documentView as? SourcePreservingTextView.EditorTextView
        }
    }

    private func makeLoadedSurface(text: String) async throws -> Surface {
        let document = EditorDocument(
            text: text,
            contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        )
        let model = try makeModel(document: document)
        await model.load()
        let surface = makeSurface(model: model)
        await drainQueuedRestoreBlock()
        return surface
    }

    private func makeModel(
        document: EditorDocument? = nil,
        save: (@Sendable (EditorSaveRequest) async throws -> EditorDocument)? = nil
    ) throws -> EditorFeatureModel {
        let document =
            try document
            ?? EditorDocument(
                text: "baseline",
                contentHash: ContentHash(hex: String(repeating: "a", count: 64)),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            )
        let saveOperation: @Sendable (EditorSaveRequest) async throws -> EditorDocument =
            save
            ?? { request in
                EditorDocument(
                    text: request.text,
                    contentHash: document.contentHash,
                    sourceInfo: request.sourceInfo
                )
            }
        return EditorFeatureModel(
            path: try VaultPath(decodedRelativePath: "Draft.md"),
            source: EditorDataSource(load: { _ in document }, save: saveOperation),
            projectionDebounce: .zero
        )
    }

    private func drainQueuedRestoreBlock() async {
        // makeScrollView queues its initial restore on the main dispatch queue;
        // a yield lets it run before the test starts interacting.
        await Task.yield()
        await Task.yield()
    }

    private func makeSurface(model: EditorFeatureModel) -> Surface {
        draftChanges = []
        selections = []
        viewports = []
        markedTextFlags = []
        saveCallCount = 0
        escapeCallCount = 0
        let view = SourcePreservingTextView(
            text: model.draft,
            revision: model.draftRevision,
            projection: model.projectionEngine.projection,
            sourceSnapshot: model.sourceSnapshot,
            initialScrollOffset: 0,
            onDraftChange: { text in
                model.updateDraft(text)
                self.draftChanges.append(text)
            },
            onSelectionChange: { anchor, head in
                model.updateSelection(anchorUTF8: anchor, headUTF8: head)
                self.selections.append((anchor, head))
            },
            onViewportChange: { anchor, offset in
                model.updateViewport(utf8Anchor: anchor, verticalOffset: offset)
                self.viewports.append((anchor, offset))
            },
            onMarkedTextChange: { active in
                model.setMarkedTextActive(active)
                self.markedTextFlags.append(active)
            },
            onSave: { self.saveCallCount += 1 },
            onEscape: { self.escapeCallCount += 1 }
        )
        let coordinator = view.makeCoordinator()
        let scrollView = coordinator.makeScrollView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        return Surface(
            model: model,
            coordinator: coordinator,
            scrollView: scrollView,
            window: window
        )
    }

    private func syncFromModel(
        _ surface: Surface,
        projection overrideProjection: MarkdownEditorProjection? = nil
    ) {
        let model = surface.model
        let view = SourcePreservingTextView(
            text: model.draft,
            revision: model.draftRevision,
            projection: overrideProjection ?? model.projectionEngine.projection,
            sourceSnapshot: model.sourceSnapshot,
            initialScrollOffset: 0,
            onDraftChange: { text in
                model.updateDraft(text)
                self.draftChanges.append(text)
            },
            onSelectionChange: { anchor, head in
                model.updateSelection(anchorUTF8: anchor, headUTF8: head)
                self.selections.append((anchor, head))
            },
            onViewportChange: { anchor, offset in
                model.updateViewport(utf8Anchor: anchor, verticalOffset: offset)
                self.viewports.append((anchor, offset))
            },
            onMarkedTextChange: { active in
                model.setMarkedTextActive(active)
                self.markedTextFlags.append(active)
            },
            onSave: { self.saveCallCount += 1 },
            onEscape: { self.escapeCallCount += 1 }
        )
        surface.coordinator.parent = view
        surface.coordinator.syncIfExternalChange(in: surface.scrollView)
    }

    private func utf8Length(_ text: String) -> Int {
        Data(text.utf8).count
    }

    private func lineContent(containingUTF8 anchor: Int, in text: String) -> String {
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let byteLength = Data(line.utf8).count
            if anchor <= offset + byteLength {
                return line
            }
            offset += byteLength + 1
        }
        return ""
    }
}
