import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import BearObsMarkdown
#endif

/// Layout metrics shared by the reader and the inline editor so both states of
/// the detail column present the same content column (REQ-002 5.3).
enum ReaderEditorLayoutToken {
    static let contentMaxWidth: CGFloat = 760
    static let contentHorizontalPadding: CGFloat = 20
    static let contentVerticalPadding: CGFloat = 24
    /// Text column width inside the editor surface once the shared horizontal
    /// padding is subtracted from the reader content width.
    static let editorTextColumnWidth = contentMaxWidth - contentHorizontalPadding * 2
}

/// The single native editing surface for the detail column (REQ-002 5.2). The
/// text storage always holds the raw Markdown draft; every attribute applied
/// here is temporary presentation derived from the projection and is never
/// serialized.
///
/// SwiftUI updates are revision-gated: the storage is rewritten only when the
/// model published a revision whose text differs from what this view's own
/// edits produced. External rewrites land as one undoable change and preserve
/// the selection and the first visible line; input-method composition is never
/// interrupted; Escape and Command-S route through the callbacks below so
/// saving keeps `EditorFeatureModel.save` as its only path.
struct SourcePreservingTextView: NSViewRepresentable {
    /// Draft text to display; it belongs to the revision below.
    let text: String
    /// Model draft revision that `text` belongs to.
    let revision: Int
    /// Latest projection for the draft; nil while the first parse is pending.
    let projection: MarkdownEditorProjection?
    /// Baseline snapshot used for the cheap first-paint projection.
    let sourceSnapshot: MarkdownSourceSnapshot?
    /// The reader viewport frozen when this session began, in original file
    /// byte coordinates. Restore scrolls the recorded block back into view
    /// and places the insertion point inside the visible area (REQ-002 6.2).
    let initialViewport: ReaderViewportSnapshot?
    let onDraftChange: (String) -> Void
    /// UTF-8 anchor/head of the selection at scalar boundaries.
    let onSelectionChange: (_ anchorUTF8: Int, _ headUTF8: Int) -> Void
    /// First visible character anchor and its vertical offset inside the line.
    let onViewportChange: (_ utf8Anchor: Int, _ verticalOffset: Double) -> Void
    let onMarkedTextChange: (Bool) -> Void
    let onSave: () -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncIfExternalChange(in: scrollView)
    }

    /// NSTextView subclass owning the hooks SwiftUI cannot reach: the Command-S
    /// key equivalent, the Escape path, input-method marked-text
    /// notifications, and the checkbox press target (REQ-002 P4). TextKit 1 is
    /// constructed explicitly so the character and glyph mapping used for
    /// UTF-8 restoration stays deterministic.
    final class EditorTextView: NSTextView {
        var onCommandSave: (() -> Void)?
        var onCommandEscape: (() -> Void)?
        var onMarkedTextChange: ((Bool) -> Void)?
        /// Called for a plain single click with the point in view coordinates.
        /// Returns true when the press was consumed (checkbox toggle) so the
        /// event must not fall through to selection handling.
        var onPressAtPoint: ((NSPoint) -> Bool)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.type == .keyDown,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                event.charactersIgnoringModifiers == "s"
            {
                onCommandSave?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.type == .leftMouseDown,
                event.clickCount == 1,
                event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                let onPressAtPoint,
                onPressAtPoint(convert(event.locationInWindow, from: nil))
            {
                return
            }
            super.mouseDown(with: event)
        }

        override func cancelOperation(_ sender: Any?) {
            // While composition is live, Escape belongs to the input method:
            // it cancels the marked text before this selector is dispatched.
            // Neither NSTextView nor NSResponder implements cancelOperation: on
            // current macOS, so there is no super action to preserve.
            guard !hasMarkedText() else { return }
            onCommandEscape?()
        }

        override func setMarkedText(
            _ string: Any,
            selectedRange: NSRange,
            replacementRange: NSRange
        ) {
            super.setMarkedText(
                string, selectedRange: selectedRange, replacementRange: replacementRange)
            onMarkedTextChange?(hasMarkedText())
        }

        override func unmarkText() {
            super.unmarkText()
            onMarkedTextChange?(false)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            centerTextColumn(forWidth: newSize.width)
        }

        /// Keeps the text column as wide as the reader's content column and
        /// centered in the detail surface instead of stretching edge to edge.
        private func centerTextColumn(forWidth width: CGFloat) {
            let horizontal = max(
                ReaderEditorLayoutToken.contentHorizontalPadding,
                (width - ReaderEditorLayoutToken.editorTextColumnWidth) / 2
            )
            let inset = NSSize(width: horizontal, height: textContainerInset.height)
            if textContainerInset != inset {
                textContainerInset = inset
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourcePreservingTextView

        private var knownRevision: Int
        private var isApplyingExternalChange = false
        private var lastAppliedProjection: MarkdownEditorProjection?
        private var lastReportedSelection: SelectionAnchor?
        private weak var observedScrollView: NSScrollView?
        private var hasRestoredInitialContext = false
        private var coordinateMapCache: (text: String, map: MarkdownTextCoordinateMap)?
        /// VoiceOver announcements for task and opaque-region interaction.
        /// The default posts an accessibility announcement; tests inject a
        /// recorder.
        var accessibilityAnnouncer: ((String) -> Void)?

        private struct SelectionAnchor: Equatable {
            let anchorUTF8: Int
            let headUTF8: Int
        }

        private struct ScrollAnchor: Equatable {
            let utf8Offset: Int
            let offsetWithinLine: CGFloat
        }

        init(parent: SourcePreservingTextView) {
            self.parent = parent
            knownRevision = parent.revision
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false

            let storage = NSTextStorage(string: parent.text)
            let layoutManager = EditorSurfaceLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(
                size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
            )
            container.widthTracksTextView = true
            layoutManager.addTextContainer(container)

            let textView = EditorTextView(
                frame: NSRect(origin: .zero, size: scrollView.contentSize),
                textContainer: container
            )
            textView.delegate = self
            textView.allowsUndo = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsImageEditing = false
            textView.isAutomaticLinkDetectionEnabled = false
            textView.isAutomaticDataDetectionEnabled = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticTextCompletionEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.usesFindBar = true
            textView.drawsBackground = false
            textView.minSize = NSSize(width: 0, height: 0)
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainerInset = NSSize(
                width: ReaderEditorLayoutToken.contentHorizontalPadding,
                height: ReaderEditorLayoutToken.contentVerticalPadding
            )
            textView.setAccessibilityLabel("可编辑笔记内容")
            textView.setAccessibilityHelp("内容在当前详情栏内编辑；按 Command-S 保存，按 Escape 结束编辑")
            textView.setAccessibilityIdentifier("inline-editor-text")
            textView.onCommandSave = { [weak self] in self?.parent.onSave() }
            textView.onCommandEscape = { [weak self] in self?.parent.onEscape() }
            textView.onMarkedTextChange = { [weak self] active in
                self?.parent.onMarkedTextChange(active)
            }
            textView.onPressAtPoint = { [weak self, weak textView] point in
                guard let self, let textView else { return false }
                return self.handlePress(at: point, in: textView)
            }
            accessibilityAnnouncer = { [weak textView] message in
                guard let textView else { return }
                NSAccessibility.post(
                    element: textView,
                    notification: .announcementRequested,
                    userInfo: [.announcement: message]
                )
            }
            textView.typingAttributes = MarkdownEditorPresentation().baseAttributes

            scrollView.documentView = textView
            observedScrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(scrollBoundsDidChange(_:)),
                name: NSClipView.boundsDidChangeNotification,
                object: scrollView.contentView
            )

            applyProjectionIfChanged(to: textView, in: scrollView)
            refreshInteraction(in: textView, announcing: false)
            restoreInitialContext(in: scrollView)
            return scrollView
        }

        func syncIfExternalChange(in scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? EditorTextView else { return }
            // The storage must not be touched while input-method composition is
            // live: the draft string cannot represent marked text (REQ-002 6.3).
            guard !textView.hasMarkedText() else { return }
            if parent.revision != knownRevision {
                knownRevision = parent.revision
                if textView.string != parent.text {
                    replaceExternal(parent.text, in: textView, scrollView: scrollView)
                }
            }
            applyProjectionIfChanged(to: textView, in: scrollView)
            refreshInteraction(in: textView, announcing: false)
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard
                !isApplyingExternalChange,
                let textView = notification.object as? EditorTextView
            else { return }
            parent.onDraftChange(textView.string)
            // The selection callback may have fired against the previous draft
            // length during the edit; re-report it so the model clamps against
            // the updated byte length. Bypass the dedupe: the same UTF-8 range
            // can clamp to a different value now.
            let selection = savedSelection(in: textView)
            lastReportedSelection = selection
            parent.onSelectionChange(selection.anchorUTF8, selection.headUTF8)
            // Typing above the viewport shifts the first visible character
            // without a scroll event; re-derive the anchor from live geometry
            // so the model's viewport stays in current-draft coordinates for
            // the reader restore on exit.
            if let scrollView = textView.enclosingScrollView,
                let anchor = firstVisibleScrollAnchor(in: textView, scrollView: scrollView)
            {
                parent.onViewportChange(anchor.utf8Offset, Double(anchor.offsetWithinLine))
            }
            refreshInteraction(in: textView, announcing: false)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard
                !isApplyingExternalChange,
                let textView = notification.object as? EditorTextView
            else { return }
            let selection = savedSelection(in: textView)
            guard selection != lastReportedSelection else { return }
            lastReportedSelection = selection
            parent.onSelectionChange(selection.anchorUTF8, selection.headUTF8)
            refreshInteraction(in: textView, announcing: true)
        }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, url.scheme == EditorTaskMarkerLink.scheme else {
                return false
            }
            guard
                let editorTextView = textView as? EditorTextView,
                let storage = editorTextView.textStorage,
                storage.length > 0
            else { return true }
            let clamped = min(max(0, charIndex), storage.length - 1)
            // The link attribute run is the marker; fall back to a narrow text
            // search when attributes are stale. Either way `toggleTaskMarker`
            // verifies the bytes are exactly `[ ]`/`[x]` before rewriting.
            let markerRange =
                (editorTextView.layoutManager as? EditorSurfaceLayoutManager)?
                .taskMarkerRange(containingUTF16: clamped)
                ?? Self.markerRange(containing: clamped, in: editorTextView.string as NSString)
            guard markerRange.location != NSNotFound else { return true }
            toggleTaskMarker(range: markerRange, in: editorTextView)
            return true
        }

        // MARK: - Task marker and opaque interaction (REQ-002 P4)

        private func handlePress(at viewPoint: NSPoint, in textView: EditorTextView) -> Bool {
            guard
                let container = textView.textContainer,
                let layoutManager = textView.layoutManager as? EditorSurfaceLayoutManager
            else { return false }
            let containerPoint = NSPoint(
                x: viewPoint.x - textView.textContainerOrigin.x,
                y: viewPoint.y - textView.textContainerOrigin.y
            )
            guard
                let marker = layoutManager.taskMarkerRange(at: containerPoint, in: container)
            else { return false }
            return toggleTaskMarker(range: marker, in: textView)
        }

        /// Replaces exactly the current `[ ]`/`[x]` bytes at `range` with the
        /// opposite marker. The edit goes through the text view's own editing
        /// pipeline, so it is undoable and reaches the model through the same
        /// draft callback as typing — there is no second save path.
        @discardableResult
        func toggleTaskMarker(range: NSRange, in textView: EditorTextView) -> Bool {
            guard
                let storage = textView.textStorage,
                storage.length > 0,
                range.location != NSNotFound,
                range.location >= 0,
                NSMaxRange(range) <= storage.length
            else { return false }
            let current = storage.attributedSubstring(from: range).string
            let replacement: String
            switch current {
            case "[ ]": replacement = "[x]"
            case "[x]": replacement = "[ ]"
            default: return false
            }
            guard textView.shouldChangeText(in: range, replacementString: replacement) else {
                return false
            }
            storage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
            announce(current == "[ ]" ? "已完成任务" : "未完成任务")
            return true
        }

        /// Recomputes the focus-sensitive presentation after a selection or
        /// draft change: invalidates the drawing of regions whose focus state
        /// flipped, refreshes the accessibility actions for the task under the
        /// caret, and — for user-driven changes — announces entering a task
        /// line or a local source region.
        private func refreshInteraction(in textView: EditorTextView, announcing: Bool) {
            guard
                let layoutManager = textView.layoutManager as? EditorSurfaceLayoutManager
            else { return }
            let previousSelection = layoutManager.selection
            let newSelection = textView.selectedRange()
            let previousFocus = layoutManager.interactionFocus(forSelection: previousSelection)
            layoutManager.selection = newSelection
            let newFocus = layoutManager.interactionFocus(forSelection: newSelection)
            if previousFocus != newFocus {
                var affected: [NSRange] = []
                for marker in previousFocus.focusedMarkers + newFocus.focusedMarkers {
                    affected.append(layoutManager.lineRange(containingUTF16: marker))
                }
                if previousFocus.hasFocusedOpaque { affected.append(previousFocus.focusedOpaque) }
                if newFocus.hasFocusedOpaque { affected.append(newFocus.focusedOpaque) }
                for range in affected where range.location != NSNotFound {
                    layoutManager.invalidateDisplay(forCharacterRange: range)
                }
            }
            updateAccessibilityActions(in: textView)
            guard announcing else { return }
            let previousMarkers = Set(previousFocus.focusedMarkers.map(\.location))
            if let marker = newFocus.focusedMarkers.first(where: {
                !previousMarkers.contains($0.location)
            }),
                let storage = textView.textStorage,
                NSMaxRange(marker) <= storage.length
            {
                let isChecked = storage.attributedSubstring(from: marker).string == "[x]"
                announce(isChecked ? "已完成任务" : "未完成任务")
            }
            if newFocus.hasFocusedOpaque,
                newFocus.focusedOpaque.location != previousFocus.focusedOpaque.location
            {
                announce("局部源码区域")
            }
        }

        /// One accessibility action for the task item under the caret; its
        /// name states the current state so VoiceOver reads out 未完成/已完成.
        private func updateAccessibilityActions(in textView: EditorTextView) {
            guard
                let layoutManager = textView.layoutManager as? EditorSurfaceLayoutManager,
                let storage = textView.textStorage,
                storage.length > 0
            else { return }
            let selection = textView.selectedRange()
            let head = min(max(0, selection.location), storage.length - 1)
            guard
                let marker = layoutManager.taskMarkerOnLine(containingUTF16Location: head),
                NSMaxRange(marker) <= storage.length
            else {
                textView.setAccessibilityCustomActions([])
                return
            }
            let isChecked = storage.attributedSubstring(from: marker).string == "[x]"
            textView.setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: isChecked ? "标记为未完成" : "标记为已完成") {
                    [weak self, weak textView] in
                    guard let self, let textView else { return false }
                    return self.toggleTaskMarker(range: marker, in: textView)
                }
            ])
        }

        private func announce(_ message: String) {
            accessibilityAnnouncer?(message)
        }

        // MARK: - External synchronization

        private func replaceExternal(
            _ newText: String,
            in textView: EditorTextView,
            scrollView: NSScrollView
        ) {
            let oldText = textView.string
            // The patch between old and new text translates selection and
            // viewport anchors across the replacement, so an insertion before
            // the visible area does not shift what the user is reading.
            let patches =
                (try? MarkdownSourcePatchBuilder.makePatches(
                    from: Data(oldText.utf8),
                    to: Data(newText.utf8)
                )) ?? []
            let selection = Self.translate(
                savedSelection(in: textView), patches: patches, to: newText)
            let scrollAnchor = firstVisibleScrollAnchor(in: textView, scrollView: scrollView)
                .map { anchor in
                    ScrollAnchor(
                        utf8Offset: Self.translate(
                            anchor.utf8Offset,
                            patches: patches,
                            to: newText
                        ),
                        offsetWithinLine: anchor.offsetWithinLine
                    )
                }
            let fullRange = NSRange(location: 0, length: (oldText as NSString).length)
            isApplyingExternalChange = true
            defer { isApplyingExternalChange = false }
            // Registering the rewrite through shouldChangeText keeps it in the
            // text view's undo stack instead of erasing user history.
            if textView.shouldChangeText(in: fullRange, replacementString: newText) {
                textView.textStorage?.replaceCharacters(in: fullRange, with: newText)
                textView.didChangeText()
            }
            restoreSelection(selection, in: textView)
            if let scrollAnchor {
                restoreScrollAnchor(scrollAnchor, in: textView, scrollView: scrollView)
            }
        }

        // MARK: - Projection presentation

        private func applyProjectionIfChanged(
            to textView: EditorTextView,
            in scrollView: NSScrollView
        ) {
            guard let projection = resolvedProjection(for: textView.string) else { return }
            guard projection != lastAppliedProjection else { return }
            lastAppliedProjection = projection

            let selection = textView.selectedRange()
            let scrollAnchor = firstVisibleScrollAnchor(in: textView, scrollView: scrollView)
            guard let storage = textView.textStorage else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            let presentation = MarkdownEditorPresentation()
            storage.beginEditing()
            if fullRange.length > 0 {
                storage.setAttributes(presentation.baseAttributes, range: fullRange)
                let map = coordinateMap(for: textView.string)
                for run in projection.runs {
                    guard let utf16Range = map.utf16Range(forUTF8: run.range) else { continue }
                    storage.addAttributes(
                        presentation.attributes(for: run.token),
                        range: NSRange(utf16Range)
                    )
                }
            }
            storage.endEditing()
            textView.setSelectedRange(selection)
            if let scrollAnchor {
                restoreScrollAnchor(scrollAnchor, in: textView, scrollView: scrollView)
            }
        }

        private func resolvedProjection(for displayText: String) -> MarkdownEditorProjection? {
            if let parentProjection = parent.projection {
                return parentProjection.text == displayText ? parentProjection : nil
            }
            // First paint before the engine's first debounced result lands: the
            // snapshot path reuses baseline ranges, so building it here is cheap.
            guard lastAppliedProjection == nil else { return nil }
            return MarkdownEditorProjectionBuilder.build(
                text: displayText,
                snapshot: parent.sourceSnapshot
            )
        }

        // MARK: - Selection and viewport anchors

        private func savedSelection(in textView: EditorTextView) -> SelectionAnchor {
            let range = textView.selectedRange()
            let map = coordinateMap(for: textView.string)
            let anchor = Self.utf8Offset(forUTF16: range.location, in: map)
            let head = Self.utf8Offset(forUTF16: range.location + range.length, in: map)
            return SelectionAnchor(anchorUTF8: anchor, headUTF8: head)
        }

        private func restoreSelection(_ selection: SelectionAnchor, in textView: EditorTextView) {
            let map = coordinateMap(for: textView.string)
            let limitUTF8 = textView.string.utf8.count
            let limitUTF16 = (textView.string as NSString).length
            let headUTF8 = min(max(0, selection.headUTF8), limitUTF8)
            let anchorUTF8 = min(max(0, selection.anchorUTF8), limitUTF8)
            let headUTF16 = Self.utf16Location(forUTF8: headUTF8, in: map) ?? limitUTF16
            let anchorUTF16 = Self.utf16Location(forUTF8: anchorUTF8, in: map) ?? limitUTF16
            textView.setSelectedRange(
                NSRange(
                    location: min(anchorUTF16, headUTF16),
                    length: abs(anchorUTF16 - headUTF16)
                )
            )
        }

        private func firstVisibleScrollAnchor(
            in textView: EditorTextView,
            scrollView: NSScrollView
        ) -> ScrollAnchor? {
            guard
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else { return nil }
            let visible = scrollView.contentView.bounds
            let containerPoint = NSPoint(
                x: visible.minX - textView.textContainerInset.width,
                y: visible.minY - textView.textContainerInset.height
            )
            let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: container)
            guard glyphIndex != NSNotFound, glyphIndex < layoutManager.numberOfGlyphs else {
                return nil
            }
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineTop =
                layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                .minY + textView.textContainerInset.height
            let map = coordinateMap(for: textView.string)
            return ScrollAnchor(
                utf8Offset: Self.utf8Offset(forUTF16: characterIndex, in: map),
                offsetWithinLine: max(0, visible.minY - lineTop)
            )
        }

        private func restoreScrollAnchor(
            _ anchor: ScrollAnchor,
            in textView: EditorTextView,
            scrollView: NSScrollView
        ) {
            guard
                let layoutManager = textView.layoutManager,
                layoutManager.numberOfGlyphs > 0
            else { return }
            let map = coordinateMap(for: textView.string)
            let limitUTF16 = (textView.string as NSString).length
            let utf16 = min(
                Self.utf16Location(forUTF8: anchor.utf8Offset, in: map) ?? limitUTF16, limitUTF16)
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: utf16)
            guard glyphIndex != NSNotFound, glyphIndex < layoutManager.numberOfGlyphs else {
                return
            }
            let lineTop =
                layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
                .minY + textView.textContainerInset.height
            scrollView.contentView.scroll(
                to: NSPoint(x: 0, y: max(0, lineTop + anchor.offsetWithinLine)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        @objc private func scrollBoundsDidChange(_ notification: Notification) {
            guard
                let contentView = notification.object as? NSClipView,
                let scrollView = observedScrollView,
                contentView === scrollView.contentView
            else { return }
            reportViewport(in: scrollView)
        }

        private func reportViewport(in scrollView: NSScrollView) {
            guard let textView = scrollView.documentView as? EditorTextView else { return }
            guard let anchor = firstVisibleScrollAnchor(in: textView, scrollView: scrollView) else {
                return
            }
            parent.onViewportChange(anchor.utf8Offset, Double(anchor.offsetWithinLine))
        }

        private func restoreInitialContext(in scrollView: NSScrollView) {
            guard !hasRestoredInitialContext else { return }
            hasRestoredInitialContext = true
            DispatchQueue.main.async {
                guard let textView = scrollView.documentView as? EditorTextView else { return }
                self.restoreReaderViewport(in: scrollView, textView: textView)
                self.reportViewport(in: scrollView)
            }
        }

        /// Reader → editor position continuity (REQ-002 6.2): scroll the
        /// reader's topmost visible block back to its recorded offset, then
        /// put the insertion point at the first editable position inside the
        /// visible area. Without a reader anchor the surface opens at the
        /// top; the document start is never assumed when an anchor exists.
        private func restoreReaderViewport(
            in scrollView: NSScrollView,
            textView: EditorTextView
        ) {
            guard let snapshot = parent.initialViewport else { return }
            guard
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else { return }
            // The restore may run before the host completed its first layout
            // pass; force the layout and grow the text view to the full
            // content height so the geometry below is real, not placeholder.
            layoutManager.ensureLayout(for: container)
            let usedHeight =
                layoutManager.usedRect(for: container).height
                + textView.textContainerInset.height * 2
            if textView.frame.height < usedHeight {
                textView.setFrameSize(
                    NSSize(width: textView.frame.width, height: usedHeight))
            }
            guard layoutManager.numberOfGlyphs > 0 else { return }

            let map = coordinateMap(for: textView.string)
            let bomShift = (parent.sourceSnapshot?.sourceInfo.hasUTF8BOM ?? false) ? 3 : 0
            let anchorUTF8 = min(
                max(snapshot.anchorSourceOffset - bomShift, 0),
                textView.string.utf8.count
            )
            guard
                let anchorUTF16 = Self.utf16Location(forUTF8: anchorUTF8, in: map)
            else { return }
            let anchorGlyph = layoutManager.glyphIndexForCharacter(at: anchorUTF16)
            guard anchorGlyph != NSNotFound, anchorGlyph < layoutManager.numberOfGlyphs else {
                return
            }
            let anchorLineRect = layoutManager.lineFragmentRect(
                forGlyphAt: anchorGlyph,
                effectiveRange: nil
            )
            let anchorLineTop = anchorLineRect.minY + textView.textContainerInset.height

            // The recorded offset is the reader's block top relative to its
            // viewport top. Scroll that far past the block's first line, but
            // never past the block's own extent in editor metrics: typography
            // is shared, yet a one-line block cut by a few points must still
            // show the block itself.
            let target: CGFloat
            if snapshot.verticalOffset < 0 {
                let blockHeight = Self.blockHeight(
                    sourceRange: snapshot.blockSourceRange,
                    bomShift: bomShift,
                    textView: textView,
                    map: map
                )
                let deeperScroll = min(
                    -snapshot.verticalOffset,
                    max(0, blockHeight - anchorLineRect.height)
                )
                target = max(0, anchorLineTop + deeperScroll)
            } else {
                target = max(0, anchorLineTop - snapshot.verticalOffset)
            }
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            if let insertion = firstEditableUTF8Offset(
                inVisibleAreaOf: textView,
                scrollView: scrollView,
                projection: resolvedProjection(for: textView.string)
            ), let insertionUTF16 = Self.utf16Location(forUTF8: insertion, in: map) {
                textView.setSelectedRange(NSRange(location: insertionUTF16, length: 0))
            }
        }

        /// The first position inside the visible area that is not part of an
        /// opaque local-source region. When the whole visible area is opaque,
        /// the visible start itself is returned so the caret focuses the
        /// local source region (REQ-002 6.2).
        private func firstEditableUTF8Offset(
            inVisibleAreaOf textView: EditorTextView,
            scrollView: NSScrollView,
            projection: MarkdownEditorProjection?
        ) -> Int? {
            guard
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer
            else { return nil }
            // glyphRange(forBoundingRect:) works in container coordinates;
            // visibleRect is in view coordinates.
            var bounding = textView.visibleRect
            bounding.origin.x -= textView.textContainerOrigin.x
            bounding.origin.y -= textView.textContainerOrigin.y
            let glyphRange = layoutManager.glyphRange(
                forBoundingRect: bounding,
                in: container
            )
            guard
                glyphRange.location != NSNotFound,
                glyphRange.length > 0,
                NSMaxRange(glyphRange) <= layoutManager.numberOfGlyphs
            else { return nil }
            let map = coordinateMap(for: textView.string)
            let firstCharacter = layoutManager.characterIndexForGlyph(
                at: glyphRange.location
            )
            let lastCharacter = layoutManager.characterIndexForGlyph(
                at: NSMaxRange(glyphRange) - 1
            )
            guard firstCharacter != NSNotFound, lastCharacter != NSNotFound else { return nil }
            var candidate = Self.utf8Offset(forUTF16: firstCharacter, in: map)
            let visibleEnd = Self.utf8Offset(forUTF16: lastCharacter, in: map)
            if let runs = projection?.runs {
                for run in runs where run.token == .opaque {
                    guard run.range.upperBound > candidate else { continue }
                    guard run.range.lowerBound <= candidate else { break }
                    candidate = run.range.upperBound
                }
            }
            guard candidate <= visibleEnd else {
                return Self.utf8Offset(forUTF16: firstCharacter, in: map)
            }
            return candidate
        }

        /// The editor-space height of the anchored block's source range.
        private static func blockHeight(
            sourceRange: Range<Int>,
            bomShift: Int,
            textView: EditorTextView,
            map: MarkdownTextCoordinateMap
        ) -> CGFloat {
            guard
                let layoutManager = textView.layoutManager,
                let container = textView.textContainer,
                let lowerUTF16 = Self.utf16Location(
                    forUTF8: max(sourceRange.lowerBound - bomShift, 0), in: map),
                let upperUTF16 = Self.utf16Location(
                    forUTF8: min(sourceRange.upperBound - bomShift, textView.string.utf8.count),
                    in: map),
                lowerUTF16 < upperUTF16
            else { return 0 }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: lowerUTF16, length: upperUTF16 - lowerUTF16),
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return 0 }
            return layoutManager.boundingRect(forGlyphRange: glyphRange, in: container).height
        }

        // MARK: - Coordinates

        /// Translates an offset in the old draft to the equivalent offset in
        /// the new draft by walking the disjoint ordered patches. Offsets inside
        /// a replaced region clamp to the region start; offsets past the end of
        /// the new text clamp to its length.
        private static func translate(
            _ offset: Int,
            patches: [MarkdownSourcePatch],
            to newText: String
        ) -> Int {
            var translated = max(0, offset)
            for patch in patches {
                // An anchor exactly on an insertion boundary keeps its offset:
                // it stays attached to the same content character instead of
                // sliding past inserted bytes.
                if patch.range.upperBound < translated {
                    translated += patch.replacement.count - patch.range.count
                } else if patch.range.lowerBound <= translated {
                    translated = patch.range.lowerBound
                    break
                } else {
                    break
                }
            }
            return min(translated, newText.utf8.count)
        }

        private static func translate(
            _ selection: SelectionAnchor,
            patches: [MarkdownSourcePatch],
            to newText: String
        ) -> SelectionAnchor {
            SelectionAnchor(
                anchorUTF8: translate(selection.anchorUTF8, patches: patches, to: newText),
                headUTF8: translate(selection.headUTF8, patches: patches, to: newText)
            )
        }

        private func coordinateMap(for text: String) -> MarkdownTextCoordinateMap {
            if let cached = coordinateMapCache, cached.text == text {
                return cached.map
            }
            let map = MarkdownTextCoordinateMap(text: text)
            coordinateMapCache = (text, map)
            return map
        }

        private static func utf8Offset(
            forUTF16 location: Int,
            in map: MarkdownTextCoordinateMap
        ) -> Int {
            var probe = location
            while probe >= 0 {
                if let offset = map.utf8Offset(forUTF16: probe) {
                    return offset
                }
                probe -= 1
            }
            return 0
        }

        private static func utf16Location(
            forUTF8 offset: Int,
            in map: MarkdownTextCoordinateMap
        ) -> Int? {
            var probe = offset
            while probe >= 0 {
                if let range = map.utf16Range(forUTF8: probe..<probe) {
                    return range.lowerBound
                }
                probe -= 1
            }
            return nil
        }

        private static func markerRange(containing index: Int, in text: NSString) -> NSRange {
            let searchLocation = max(0, index - 2)
            let searchRange = NSRange(
                location: searchLocation,
                length: min(5, text.length - searchLocation)
            )
            let checked = text.range(of: "[x]", options: [], range: searchRange)
            if checked.location != NSNotFound {
                return checked
            }
            return text.range(of: "[ ]", options: [], range: searchRange)
        }
    }
}

/// AppKit mapping of the pure-data editor projection. Holds fonts, colors, and
/// paragraph styles only; every span and boundary decision lives in
/// `MarkdownEditorProjectionBuilder`. Typography mirrors the reader's SwiftUI
/// styles (REQ-002 5.3): semantic level sizes for headings, the reader body
/// font and line spacing for paragraphs, monospace on a light background for
/// code and opaque spans.
private struct MarkdownEditorPresentation {
    let baseAttributes: [NSAttributedString.Key: Any]

    init() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Self.readerBodyLineSpacing
        baseAttributes = [
            .font: NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
    }

    func attributes(for token: MarkdownEditorStyleToken) -> [NSAttributedString.Key: Any] {
        switch token {
        case .heading(let level):
            return [
                .font: Self.headingFont(level: level),
                .paragraphStyle: Self.headingParagraphStyle,
            ]
        case .listItem:
            return [.paragraphStyle: Self.listParagraphStyle]
        case .quote:
            return [
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: Self.quoteParagraphStyle,
            ]
        case .codeBlock:
            return Self.codeAttributes
        case .opaque:
            var attributes = Self.opaqueAttributes
            attributes[.bearobsOpaqueRegion] = true
            return attributes
        case .taskMarker:
            return Self.taskMarkerAttributes
        }
    }

    private static let readerBodyLineSpacing: CGFloat = 4

    static func headingFont(level: Int) -> NSFont {
        let style: NSFont.TextStyle
        switch level {
        case 1: style = .largeTitle
        case 2: style = .title1
        case 3: style = .title2
        default: style = .headline
        }
        let size = NSFont.preferredFont(forTextStyle: style).pointSize
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    private static var headingParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = 14
        style.paragraphSpacing = 4
        style.lineSpacing = readerBodyLineSpacing
        return style
    }

    private static var listParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 18
        style.lineSpacing = readerBodyLineSpacing
        return style
    }

    private static var quoteParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.headIndent = 12
        style.lineSpacing = readerBodyLineSpacing
        return style
    }

    private static var codeParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        return style
    }

    private static var codeAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.35),
            .paragraphStyle: codeParagraphStyle,
        ]
    }

    private static var opaqueAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(
                ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                weight: .regular
            ),
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
            .paragraphStyle: codeParagraphStyle,
        ]
    }

    private static var taskMarkerAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor.controlAccentColor,
            .link: EditorTaskMarkerLink.toggleURL,
        ]
    }
}
