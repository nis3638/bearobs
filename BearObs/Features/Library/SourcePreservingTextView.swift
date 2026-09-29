import AppKit
import SwiftUI

#if SWIFT_PACKAGE
    import BearObsMarkdown
#endif

/// A single native editing surface. Markdown text is always the source of truth;
/// the attributes below are temporary presentation only and are never serialized.
struct SourcePreservingTextView: NSViewRepresentable {
    @Binding var text: String
    let sourceSnapshot: MarkdownSourceSnapshot?
    let initialScrollOffset: CGFloat

    init(
        text: Binding<String>,
        sourceSnapshot: MarkdownSourceSnapshot?,
        initialScrollOffset: CGFloat = 0
    ) {
        _text = text
        self.sourceSnapshot = sourceSnapshot
        self.initialScrollOffset = initialScrollOffset
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.string = text
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.minSize = NSSize(width: 0, height: 360)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("可编辑笔记内容")
        textView.setAccessibilityHelp("内容在当前详情栏内编辑；按 Command-S 保存")
        textView.setAccessibilityIdentifier("inline-editor-text")
        scrollView.documentView = textView
        context.coordinator.applyPresentation(to: textView)
        context.coordinator.restoreInitialContext(in: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            context.coordinator.isSynchronizing = true
            textView.string = text
            context.coordinator.isSynchronizing = false
        }
        context.coordinator.applyPresentation(to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SourcePreservingTextView
        var isSynchronizing = false
        private var hasRestoredInitialContext = false

        init(parent: SourcePreservingTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard
                !isSynchronizing,
                let textView = notification.object as? NSTextView
            else { return }
            parent.text = textView.string
            applyPresentation(to: textView)
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            guard
                let url = link as? URL,
                url.scheme == "bearobs-task"
            else { return false }

            let content = textView.string as NSString
            let markerRange = markerRange(containing: charIndex, in: content)
            guard markerRange.location != NSNotFound else { return true }
            let replacement = content.substring(with: markerRange) == "[x]" ? "[ ]" : "[x]"
            guard textView.shouldChangeText(in: markerRange, replacementString: replacement) else {
                return true
            }
            textView.textStorage?.replaceCharacters(in: markerRange, with: replacement)
            textView.didChangeText()
            return true
        }

        func applyPresentation(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let selectedRange = textView.selectedRange()
            let text = textView.string
            let presentation = MarkdownEditorPresentation()
            storage.beginEditing()
            storage.setAttributes(
                presentation.baseAttributes,
                range: NSRange(location: 0, length: (text as NSString).length)
            )
            let coordinateMap = MarkdownTextCoordinateMap(text: text)
            if let projection = MarkdownEditorProjectionBuilder.build(
                text: text,
                snapshot: parent.sourceSnapshot
            ) {
                for run in projection.runs {
                    guard let utf16Range = coordinateMap.utf16Range(forUTF8: run.range) else {
                        continue
                    }
                    storage.addAttributes(
                        presentation.attributes(for: run.token),
                        range: NSRange(utf16Range)
                    )
                }
            }
            storage.endEditing()
            textView.setSelectedRange(selectedRange)
        }

        func restoreInitialContext(in scrollView: NSScrollView) {
            guard !hasRestoredInitialContext else { return }
            hasRestoredInitialContext = true
            DispatchQueue.main.async {
                guard let textView = scrollView.documentView as? NSTextView else { return }
                let origin = NSPoint(x: 0, y: self.parent.initialScrollOffset)
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                guard
                    let layoutManager = textView.layoutManager,
                    let container = textView.textContainer
                else { return }
                let visibleRange = layoutManager.glyphRange(
                    forBoundingRect: scrollView.contentView.bounds,
                    in: container
                )
                textView.setSelectedRange(NSRange(location: visibleRange.location, length: 0))
            }
        }

        private func markerRange(containing index: Int, in text: NSString) -> NSRange {
            let searchRange = NSRange(
                location: max(0, index - 2), length: min(5, text.length - max(0, index - 2)))
            let checked = text.range(of: "[x]", options: [], range: searchRange)
            if checked.location != NSNotFound { return checked }
            return text.range(of: "[ ]", options: [], range: searchRange)
        }
    }
}

/// AppKit mapping of the pure-data editor projection. Holds fonts, colors, and
/// paragraph styles only; every span and boundary decision lives in
/// `MarkdownEditorProjectionBuilder`.
private struct MarkdownEditorPresentation {
    let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.preferredFont(forTextStyle: .body),
        .foregroundColor: NSColor.labelColor,
    ]

    func attributes(for token: MarkdownEditorStyleToken) -> [NSAttributedString.Key: Any] {
        switch token {
        case .heading(let level):
            [.font: headingFont(level: level)]
        case .quote:
            [.foregroundColor: NSColor.secondaryLabelColor]
        case .listItem:
            [.paragraphStyle: listParagraphStyle]
        case .codeBlock, .opaque:
            opaqueAttributes
        case .taskMarker:
            taskMarkerAttributes
        }
    }

    private var opaqueAttributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12),
        ]
    }

    private var taskMarkerAttributes: [NSAttributedString.Key: Any] {
        [
            .foregroundColor: NSColor.controlAccentColor,
            .link: URL(string: "bearobs-task://toggle")!,
            .underlineStyle: 0,
        ]
    }

    private func headingFont(level: Int) -> NSFont {
        let size = NSFont.preferredFont(forTextStyle: .body).pointSize
        return NSFont.systemFont(ofSize: size + CGFloat(4 - min(level, 3)) * 2, weight: .bold)
    }

    private var listParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 0
        style.headIndent = 18
        return style
    }
}
