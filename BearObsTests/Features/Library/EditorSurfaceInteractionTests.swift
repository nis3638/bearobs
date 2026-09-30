import AppKit
import PDFKit
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

/// REQ-002 P4: task marker and opaque-region interactions. The surface must
/// toggle task markers through exactly the three marker bytes, keep opaque
/// region bytes intact while editing elsewhere, present the focused opaque
/// region as a local source region, and expose task state to accessibility.
///
/// The fixture mixes CJK text, so two coordinate systems are kept apart
/// explicitly: UTF-8 byte offsets for `Data` assertions (the canonical parser
/// coordinates) and UTF-16 offsets for every `NSTextStorage`/selection call,
/// derived through `MarkdownTextCoordinateMap`.
@MainActor
final class EditorSurfaceInteractionTests: XCTestCase {
    // Byte layout (LF-only):
    //    0..<14    "开头段落\n\n"
    //   14..<33    "- [ ] 待办任务\n"       marker bytes 16..<19
    //   33..<67    "\n%% 局部源码块\n第二行 %%\n\n" merged opaque region
    //   67..<89    "- [x] 已完成任务\n"     marker bytes 69..<72
    static let fixture = "开头段落\n\n- [ ] 待办任务\n\n%% 局部源码块\n第二行 %%\n\n- [x] 已完成任务\n"

    private static var coordinateMap: MarkdownTextCoordinateMap {
        MarkdownTextCoordinateMap(text: fixture)
    }

    private static func utf16(_ bytes: Range<Int>) -> NSRange {
        guard let range = coordinateMap.utf16Range(forUTF8: bytes) else {
            fatalError("Fixture UTF-8 range \(bytes) must map to UTF-16")
        }
        return NSRange(range)
    }

    static var blankOpaque: NSRange { utf16(13..<14) }
    static var opaqueRange: NSRange { utf16(33..<67) }
    static var uncheckedMarker: NSRange { utf16(16..<19) }
    static var checkedMarker: NSRange { utf16(69..<72) }

    func testProjectionPublishesTaskMarkerAndOpaqueGeometry() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let layoutManager = try XCTUnwrap(
            textView.layoutManager as? EditorSurfaceLayoutManager)
        let storage = try XCTUnwrap(textView.textStorage)

        let markers = layoutManager.taskMarkerRanges(
            in: NSRange(location: 0, length: storage.length))
        XCTAssertEqual(markers, [Self.uncheckedMarker, Self.checkedMarker])
        XCTAssertEqual(
            layoutManager.opaqueRanges(in: NSRange(location: 0, length: storage.length)),
            [Self.blankOpaque, Self.opaqueRange]
        )

        let opaqueHead = Self.opaqueRange.location + 8
        XCTAssertTrue(
            try XCTUnwrap(
                storage.attribute(.bearobsOpaqueRegion, at: opaqueHead, effectiveRange: nil)
                    as? Bool
            )
        )
        XCTAssertNil(storage.attribute(.bearobsOpaqueRegion, at: 0, effectiveRange: nil))
        XCTAssertEqual(
            layoutManager.taskMarkerRange(containingUTF16: Self.uncheckedMarker.location + 1),
            Self.uncheckedMarker
        )
        XCTAssertNil(layoutManager.taskMarkerRange(containingUTF16: 0))
        XCTAssertEqual(layoutManager.opaqueRange(containingUTF16: opaqueHead), Self.opaqueRange)
        XCTAssertNil(layoutManager.opaqueRange(containingUTF16: 0))
        // A blank line is a parser fallback, not a local source region the
        // user could edit: it must never carry the region presentation.
        XCTAssertNil(layoutManager.opaqueRange(containingUTF16: Self.blankOpaque.location))
        XCTAssertFalse(layoutManager.isPresentableOpaqueRange(Self.blankOpaque))
        XCTAssertTrue(layoutManager.isPresentableOpaqueRange(Self.opaqueRange))
    }

    func testTogglingTaskMarkerChangesExactlyThreeMarkerBytes() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let before = Data(surface.model.draft.utf8)
        let opaqueBefore = before.subdata(in: 33..<67)

        XCTAssertTrue(
            surface.coordinator.toggleTaskMarker(
                range: Self.uncheckedMarker, in: try XCTUnwrap(textView)))

        let after = Data(surface.model.draft.utf8)
        XCTAssertEqual(after.count, before.count)
        var diffIndices: [Int] = []
        for index in 0..<before.count where before[index] != after[index] {
            diffIndices.append(index)
        }
        // REQ-002 P4 exit: the toggle's byte diff is confined to the three
        // marker bytes — `[ ]` vs `[x]` differs only in the middle byte.
        XCTAssertFalse(diffIndices.isEmpty)
        XCTAssertTrue(
            diffIndices.allSatisfy { (16..<19).contains($0) },
            "Only bytes inside the marker range may change, got \(diffIndices)"
        )
        XCTAssertEqual(after.subdata(in: 33..<67), opaqueBefore)
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture.replacingOccurrences(
                of: "- [ ] 待办任务", with: "- [x] 待办任务")
        )
        XCTAssertTrue(surface.model.isDirty)

        XCTAssertTrue(
            surface.coordinator.toggleTaskMarker(
                range: Self.checkedMarker, in: try XCTUnwrap(textView)))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture
                .replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
                .replacingOccurrences(of: "- [x] 已完成任务", with: "- [ ] 已完成任务")
        )
    }

    func testToggleRefusesRangesThatAreNotCurrentMarkerBytes() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let original = surface.model.draft
        let content = original as NSString

        // A range over the list marker, a range inside the opaque region, and
        // a degenerate range must all be rejected: the toggle only ever
        // rewrites the current `[ ]`/`[x]` bytes.
        let listMarker = content.range(of: "- ")
        XCTAssertFalse(surface.coordinator.toggleTaskMarker(range: listMarker, in: textView))
        let comment = content.range(of: "%% ")
        XCTAssertFalse(surface.coordinator.toggleTaskMarker(range: comment, in: textView))
        XCTAssertFalse(
            surface.coordinator.toggleTaskMarker(
                range: NSRange(location: NSNotFound, length: 0), in: textView))
        XCTAssertEqual(surface.model.draft, original)
        XCTAssertEqual(textView.string, original)
    }

    func testCheckboxHitTogglesOnlyWithinTheHitArea() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let layoutManager = try XCTUnwrap(
            textView.layoutManager as? EditorSurfaceLayoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let origin = textView.textContainerOrigin
        let handler = try XCTUnwrap(textView.onPressAtPoint)

        let box = try XCTUnwrap(
            layoutManager.checkboxRect(forTaskMarker: Self.uncheckedMarker, in: container))

        // A press far from any marker is left for normal text handling.
        let farContainerPoint = NSPoint(x: 320, y: 5)
        XCTAssertNil(
            layoutManager.taskMarkerRange(at: farContainerPoint, in: container)
        )
        XCTAssertFalse(
            handler(
                NSPoint(
                    x: farContainerPoint.x + origin.x,
                    y: farContainerPoint.y + origin.y
                )))
        XCTAssertEqual(surface.model.draft, Self.fixture)

        // A press on the drawn checkbox toggles the marker.
        XCTAssertTrue(
            handler(
                NSPoint(
                    x: box.midX + origin.x,
                    y: box.midY + origin.y
                )))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture.replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
        )
    }

    func testLinkClickTogglesThroughClickedOnLink() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let coordinator = surface.coordinator
        let storage = try XCTUnwrap(textView.textStorage)

        XCTAssertTrue(
            coordinator.textView(
                textView,
                clickedOnLink: EditorTaskMarkerLink.toggleURL,
                at: Self.uncheckedMarker.location + 1
            ))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture.replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
        )

        // The fallback path works even when the link attribute is gone: the
        // marker is located by text search and verified by exact bytes.
        storage.removeAttribute(.link, range: Self.checkedMarker)
        XCTAssertTrue(
            coordinator.textView(
                textView,
                clickedOnLink: EditorTaskMarkerLink.toggleURL,
                at: Self.checkedMarker.location + 1
            ))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture
                .replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
                .replacingOccurrences(of: "- [x] 已完成任务", with: "- [ ] 已完成任务")
        )
    }

    func testAccessibilityActionTogglesTaskUnderCaret() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.accessibilityCustomActions()?.count ?? 0, 0)

        textView.setSelectedRange(NSRange(location: Self.uncheckedMarker.location + 1, length: 0))
        let actions = try XCTUnwrap(textView.accessibilityCustomActions())
        XCTAssertEqual(actions.count, 1, "Expected one toggle action at the task caret")
        guard actions.count == 1 else { return }
        XCTAssertEqual(actions[0].name, "标记为已完成")
        XCTAssertTrue(actions[0].handler?() == true)
        XCTAssertEqual(
            textView.string,
            Self.fixture.replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
        )

        textView.setSelectedRange(NSRange(location: Self.checkedMarker.location + 1, length: 0))
        let checkedActions = try XCTUnwrap(textView.accessibilityCustomActions())
        XCTAssertEqual(
            checkedActions.count, 1, "Expected one toggle action at the checked task caret")
        guard checkedActions.count == 1 else { return }
        XCTAssertEqual(checkedActions[0].name, "标记为未完成")
        XCTAssertTrue(checkedActions[0].handler?() == true)
        XCTAssertEqual(
            textView.string,
            Self.fixture
                .replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
                .replacingOccurrences(of: "- [x] 已完成任务", with: "- [ ] 已完成任务")
        )
    }

    func testSelectionAnnouncesTaskStateAndLocalSourceRegion() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        var announcements: [String] = []
        surface.coordinator.accessibilityAnnouncer = { announcements.append($0) }

        // Onto the task marker, then within the same task line (no repeat),
        // into the opaque region, onto the checked task, and back.
        textView.setSelectedRange(NSRange(location: Self.uncheckedMarker.location + 1, length: 0))
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        textView.setSelectedRange(NSRange(location: Self.opaqueRange.location + 8, length: 0))
        textView.setSelectedRange(NSRange(location: Self.checkedMarker.location + 1, length: 0))
        textView.setSelectedRange(NSRange(location: Self.opaqueRange.location + 8, length: 0))

        XCTAssertEqual(
            announcements,
            ["未完成任务", "局部源码区域", "已完成任务", "局部源码区域"]
        )
    }

    func testToggleAnnouncesTheNewTaskState() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        var announcements: [String] = []
        surface.coordinator.accessibilityAnnouncer = { announcements.append($0) }

        XCTAssertTrue(
            surface.coordinator.toggleTaskMarker(
                range: Self.uncheckedMarker, in: textView))
        XCTAssertEqual(announcements, ["已完成任务"])
    }

    func testTypingAroundOpaqueRegionPreservesItsBytes() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let storage = try XCTUnwrap(textView.textStorage)
        let opaqueText = (storage.string as NSString).substring(with: Self.opaqueRange)
        XCTAssertEqual(
            opaqueText, "\n%% 局部源码块\n第二行 %%\n\n", "Fixture layout changed")

        // Type before the region, right after it, and at the end of the note.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("前置", replacementRange: NSRange(location: NSNotFound, length: 0))
        var expected = "前置" + Self.fixture
        XCTAssertEqual(storage.string, expected)
        XCTAssertTrue(storage.string.contains(opaqueText))

        let taskStart = (expected as NSString).range(of: "- [x]").location
        textView.setSelectedRange(NSRange(location: taskStart, length: 0))
        textView.insertText("中缀\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        expected = expected.replacingOccurrences(of: "- [x]", with: "中缀\n- [x]")
        XCTAssertEqual(storage.string, expected)
        XCTAssertTrue(storage.string.contains(opaqueText))

        textView.setSelectedRange(
            NSRange(location: (expected as NSString).length, length: 0))
        textView.insertText("后缀", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(storage.string, expected + "后缀")
        XCTAssertTrue(storage.string.contains(opaqueText))
        XCTAssertEqual(surface.model.draft, expected + "后缀")
    }

    func testMarkerGlyphSuppressionFollowsTaskLineFocus() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let layoutManager = try XCTUnwrap(
            textView.layoutManager as? EditorSurfaceLayoutManager)

        // Selection away from the task line: the checkbox replaces the glyphs.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(layoutManager.isTaskMarkerSuppressed(Self.uncheckedMarker))

        // Selection inside the task line: the raw `[ ]` glyphs come back so
        // the bytes being edited stay visible.
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        XCTAssertFalse(layoutManager.isTaskMarkerSuppressed(Self.uncheckedMarker))
        XCTAssertTrue(layoutManager.isTaskMarkerSuppressed(Self.checkedMarker))

        textView.setSelectedRange(
            NSRange(location: Self.checkedMarker.location + 1, length: 0))
        XCTAssertTrue(layoutManager.isTaskMarkerSuppressed(Self.uncheckedMarker))
        XCTAssertFalse(layoutManager.isTaskMarkerSuppressed(Self.checkedMarker))
    }

    func testDrawingRendersCheckboxAndFocusedOpaqueAnnotation() async throws {
        let surface = try await makeSurface()
        let scrollView = surface.scrollView
        let textView = try XCTUnwrap(surface.textView)

        // Selection inside the opaque region exercises the focused fill,
        // border and caption path; task lines exercise checkbox drawing.
        textView.setSelectedRange(NSRange(location: Self.opaqueRange.location + 8, length: 0))
        let pdf = scrollView.dataWithPDF(inside: scrollView.bounds)
        XCTAssertFalse(pdf.isEmpty)

        // With the selection on the task line, the raw marker glyphs are
        // drawn instead of the checkbox.
        textView.setSelectedRange(NSRange(location: Self.uncheckedMarker.location + 1, length: 0))
        let focusedTaskPDF = scrollView.dataWithPDF(inside: scrollView.bounds)
        XCTAssertFalse(focusedTaskPDF.isEmpty)
        let pdfText = PDFDocument(data: focusedTaskPDF)?.string ?? ""
        XCTAssertTrue(pdfText.contains("[ ]"), "Focused task line must draw the raw marker")
    }

    func testToggleIsSingleUndoableStep() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)

        XCTAssertTrue(
            surface.coordinator.toggleTaskMarker(
                range: Self.uncheckedMarker, in: textView))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture.replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
        )

        textView.undoManager?.undo()
        XCTAssertEqual(textView.string, Self.fixture)
        XCTAssertEqual(surface.model.draft, Self.fixture)
        XCTAssertFalse(surface.model.isDirty)
    }

    // MARK: - Keyboard and announcement paths (REQ-002 P6)

    /// All structured node kinds in one document (LF-only): heading,
    /// paragraph, list item, quote, code block, opaque, task item.
    static let kindFixture = """
        # 一级标题

        正文段落

        - 列表项内容

        > 引用行

        ```
        代码块行
        ```

        %% 局部源码 %%

        - [ ] 任务一项
        """

    private static let kindMap = MarkdownTextCoordinateMap(text: kindFixture)

    /// The UTF-16 location of the first occurrence of `needle`, found in UTF-8
    /// bytes and mapped through the coordinate map.
    private static func kindLocation(_ needle: String) -> Int {
        let bytes = Array(kindFixture.utf8)
        let needleBytes = Array(needle.utf8)
        var start = 0
        while start + needleBytes.count <= bytes.count {
            let end = start + needleBytes.count
            if Array(bytes[start..<end]) == needleBytes {
                guard let range = kindMap.utf16Range(forUTF8: start..<end) else {
                    fatalError("kindFixture offset for \(needle) must map to UTF-16")
                }
                return range.lowerBound
            }
            start += 1
        }
        preconditionFailure("kindFixture is missing \(needle)")
    }

    func testCommandLKeyboardEquivalentTogglesTaskUnderCaret() async throws {
        let surface = try await makeSurface()
        let textView = try XCTUnwrap(surface.textView)
        let commandL = try makeKeyEvent("l", modifierFlags: .command)

        textView.setSelectedRange(
            NSRange(location: Self.uncheckedMarker.location + 1, length: 0))
        XCTAssertTrue(textView.performKeyEquivalent(with: commandL))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture.replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
        )

        // Off a task line the key press falls through unhandled.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertFalse(textView.performKeyEquivalent(with: commandL))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture.replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
        )

        textView.setSelectedRange(
            NSRange(location: Self.checkedMarker.location + 1, length: 0))
        XCTAssertTrue(textView.performKeyEquivalent(with: commandL))
        XCTAssertEqual(
            surface.model.draft,
            Self.fixture
                .replacingOccurrences(of: "- [ ] 待办任务", with: "- [x] 待办任务")
                .replacingOccurrences(of: "- [x] 已完成任务", with: "- [ ] 已完成任务")
        )
    }

    func testNodeTypeAnnouncementsFollowTheCaretWithoutRepeating() async throws {
        let surface = try await makeSurface(text: Self.kindFixture)
        let textView = try XCTUnwrap(surface.textView)
        var announcements: [String] = []
        surface.coordinator.accessibilityAnnouncer = { announcements.append($0) }

        func move(to needle: String) {
            textView.setSelectedRange(
                NSRange(location: Self.kindLocation(needle), length: 0))
        }

        move(to: "正文段落")
        move(to: "文段落")  // same paragraph: no repeat
        move(to: "一级标题")
        move(to: "级标题")  // same heading: no repeat
        move(to: "列表项内容")
        move(to: "引用行")
        move(to: "代码块行")
        move(to: "局部源码")
        move(to: "任务一项")
        move(to: "正文段落")

        XCTAssertEqual(
            announcements,
            [
                "段落",
                "一级标题",
                "列表项",
                "引用",
                "代码块",
                "局部源码区域",
                "未完成任务",
                "段落",
            ]
        )
    }

    func testSaveStatusTransitionsAreAnnounced() async throws {
        let surface = try await makeSurface()
        let scrollView = surface.scrollView
        var announcements: [String] = []
        surface.coordinator.accessibilityAnnouncer = { announcements.append($0) }
        let failureText =
            "\(EditorFailure.saveFailed.title)。\(EditorFailure.saveFailed.message(isDirty: true))"

        func sync(saveStatus: EditorSaveStatus) {
            syncFromModel(
                coordinator: surface.coordinator,
                scrollView: scrollView,
                model: surface.model,
                saveStatus: saveStatus
            )
        }

        sync(saveStatus: EditorSaveStatus(isSaving: true, failureText: nil))
        sync(saveStatus: EditorSaveStatus(isSaving: false, failureText: nil))
        sync(saveStatus: EditorSaveStatus(isSaving: false, failureText: failureText))
        sync(saveStatus: EditorSaveStatus(isSaving: false, failureText: failureText))
        sync(saveStatus: .idle)

        XCTAssertEqual(announcements, ["正在保存笔记", "已保存", failureText])
    }

    func testEnteringTheSurfaceAnnouncesEditingMode() async throws {
        let surface = try await makeSurface(captureAnnouncements: true)

        XCTAssertEqual(surface.announcementLog?.messages, ["已进入编辑模式"])
    }

    func testEnteringTheSurfacePromotesInitialFocus() async throws {
        let surface = try await makeSurface()

        XCTAssertTrue(
            surface.window.firstResponder === surface.textView,
            "Entering edit mode must leave the user ready to type"
        )
    }

    func testQuoteRunsCarryTheGuideLinePresentation() async throws {
        let surface = try await makeSurface(text: Self.kindFixture)
        let textView = try XCTUnwrap(surface.textView)
        let layoutManager = try XCTUnwrap(
            textView.layoutManager as? EditorSurfaceLayoutManager)
        let storage = try XCTUnwrap(textView.textStorage)
        let scrollView = surface.scrollView

        let quoteLocation = Self.kindLocation("引用行")
        let quoteRange = try XCTUnwrap(
            layoutManager.quoteRanges(
                in: NSRange(location: 0, length: storage.length)
            ).first
        )
        // The run spans the whole quote node including the `>` bytes, so the
        // guide line covers the line the caret is on.
        XCTAssertEqual(quoteRange.location, Self.kindLocation("> 引用行"))
        XCTAssertTrue(NSLocationInRange(quoteLocation, quoteRange))
        XCTAssertTrue(
            try XCTUnwrap(
                storage.attribute(.bearobsQuoteRegion, at: quoteLocation, effectiveRange: nil)
                    as? Bool
            )
        )
        XCTAssertNil(
            storage.attribute(.bearobsQuoteRegion, at: 0, effectiveRange: nil))

        textView.setSelectedRange(NSRange(location: quoteLocation, length: 0))
        let pdf = scrollView.dataWithPDF(inside: scrollView.bounds)
        XCTAssertFalse(pdf.isEmpty)
    }

    private func makeKeyEvent(
        _ characters: String,
        modifierFlags: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            )
        )
    }

    // MARK: - Helpers

    @MainActor
    private final class AnnouncementLog {
        var messages: [String] = []
    }

    @MainActor
    private struct Surface {
        let model: EditorFeatureModel
        let coordinator: SourcePreservingTextView.Coordinator
        let scrollView: NSScrollView
        let window: NSWindow
        let announcementLog: AnnouncementLog?

        var textView: SourcePreservingTextView.EditorTextView? {
            scrollView.documentView as? SourcePreservingTextView.EditorTextView
        }
    }

    private func makeSurface(
        text: String = EditorSurfaceInteractionTests.fixture,
        captureAnnouncements: Bool = false
    ) async throws -> Surface {
        let document = EditorDocument(
            text: text,
            contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        )
        let model = EditorFeatureModel(
            path: try VaultPath(decodedRelativePath: "Draft.md"),
            source: EditorDataSource(
                load: { _ in document },
                save: { request in
                    EditorDocument(
                        text: request.text,
                        contentHash: document.contentHash,
                        sourceInfo: request.sourceInfo
                    )
                }
            ),
            projectionDebounce: .zero
        )
        await model.load()

        let view = SourcePreservingTextView(
            text: model.draft,
            revision: model.draftRevision,
            projection: model.projectionEngine.projection,
            sourceSnapshot: model.sourceSnapshot,
            initialViewport: nil,
            saveStatus: .idle,
            onDraftChange: { model.updateDraft($0) },
            onSelectionChange: { anchor, head in
                model.updateSelection(anchorUTF8: anchor, headUTF8: head)
            },
            onViewportChange: { anchor, offset in
                model.updateViewport(utf8Anchor: anchor, verticalOffset: offset)
            },
            onMarkedTextChange: { model.setMarkedTextActive($0) },
            onSave: {},
            onEscape: {}
        )
        let coordinator = view.makeCoordinator()
        let scrollView = coordinator.makeScrollView()
        let announcementLog = AnnouncementLog()
        if captureAnnouncements {
            coordinator.accessibilityAnnouncer = { announcementLog.messages.append($0) }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        // Let the engine's first debounced projection land and the queued
        // initial restore run, then re-sync so geometry reflects the
        // published projection.
        for _ in 0..<8 { await Task.yield() }
        syncFromModel(coordinator: coordinator, scrollView: scrollView, model: model)
        return Surface(
            model: model,
            coordinator: coordinator,
            scrollView: scrollView,
            window: window,
            announcementLog: captureAnnouncements ? announcementLog : nil
        )
    }

    private func syncFromModel(
        coordinator: SourcePreservingTextView.Coordinator,
        scrollView: NSScrollView,
        model: EditorFeatureModel,
        saveStatus: EditorSaveStatus = .idle
    ) {
        coordinator.parent = SourcePreservingTextView(
            text: model.draft,
            revision: model.draftRevision,
            projection: model.projectionEngine.projection,
            sourceSnapshot: model.sourceSnapshot,
            initialViewport: nil,
            saveStatus: saveStatus,
            onDraftChange: { model.updateDraft($0) },
            onSelectionChange: { anchor, head in
                model.updateSelection(anchorUTF8: anchor, headUTF8: head)
            },
            onViewportChange: { anchor, offset in
                model.updateViewport(utf8Anchor: anchor, verticalOffset: offset)
            },
            onMarkedTextChange: { model.setMarkedTextActive($0) },
            onSave: {},
            onEscape: {}
        )
        coordinator.syncIfExternalChange(in: scrollView)
    }
}
