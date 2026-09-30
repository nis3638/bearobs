import AppKit

/// Link URL applied to task marker ranges so clicks reach the toggle path.
enum EditorTaskMarkerLink {
    static let scheme = "bearobs-task"
    static let toggleURL = URL(string: "\(scheme)://toggle")!
}

extension NSAttributedString.Key {
    /// Presentation-only tag on opaque (local source) regions of the editor
    /// draft. The text storage keeps raw Markdown; this key lets drawing and
    /// hit-testing derive region geometry from attributes that shift with
    /// every edit, so there is no cached geometry to go stale.
    static let bearobsOpaqueRegion = NSAttributedString.Key("com.bearobs.editor.opaqueRegion")
}

/// Focus-sensitive interaction state derived from the selection (REQ-002 P4).
struct EditorSurfaceInteractionFocus: Equatable {
    /// Task markers whose enclosing line intersects the selection; their
    /// glyphs are shown raw instead of drawn as a checkbox.
    var focusedMarkers: [NSRange] = []
    /// Opaque region containing the selection head, `location == NSNotFound`
    /// when the head is outside every presentable opaque region.
    var focusedOpaque = NSRange(location: NSNotFound, length: 0)

    var hasFocusedOpaque: Bool { focusedOpaque.location != NSNotFound }
}

/// Layout manager of the inline editing surface (REQ-002 P4). It derives all
/// task-marker and opaque-region state live from the text storage's
/// presentation attributes, and draws:
///
/// - a checkbox in place of the `[ ]`/`[x]` glyphs; the raw glyphs return
///   while the selection sits on the marker's line so edited bytes stay
///   visible;
/// - a stronger fill, a border, and the "局部源码区域" caption for the opaque
///   region under the selection head (REQ-002 5.3).
///
/// Nothing here changes the draft bytes; every presentation is derived and
/// redrawn from the current attributes.
final class EditorSurfaceLayoutManager: NSLayoutManager {
    /// UTF-16 selection of the hosting text view, kept current by the
    /// coordinator before any redraw or interaction decision.
    var selection = NSRange(location: 0, length: 0)

    private static let checkboxSide: CGFloat = 13
    private static let checkboxHitPadding: CGFloat = 3

    private lazy var checkboxImages: (checked: NSImage, unchecked: NSImage) = {
        let image: (String) -> NSImage = { name in
            let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            return base?.withSymbolConfiguration(
                .init(hierarchicalColor: NSColor.controlAccentColor)
            ) ?? NSImage()
        }
        return (image("checkmark.square.fill"), image("square"))
    }()

    private lazy var opaqueCaption: NSAttributedString = NSAttributedString(
        string: "局部源码区域",
        attributes: [
            .font: NSFont.preferredFont(forTextStyle: .caption2),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    )

    // MARK: - Geometry from attributes

    /// Task marker ranges (`[ ]`/`[x]` runs carrying the toggle link).
    func taskMarkerRanges(in range: NSRange) -> [NSRange] {
        rangesOfAttribute(.link, in: range) { ($0 as? URL)?.scheme == EditorTaskMarkerLink.scheme }
    }

    /// Opaque region ranges tagged by the projection presentation.
    func opaqueRanges(in range: NSRange) -> [NSRange] {
        rangesOfAttribute(.bearobsOpaqueRegion, in: range) { ($0 as? Bool) == true }
    }

    /// Opaque regions that carry visible content. The parser's blank-line
    /// fallback is opaque but not a source region the user edits, so it never
    /// receives the region presentation.
    func isPresentableOpaqueRange(_ range: NSRange) -> Bool {
        guard
            let storage = textStorage,
            range.location != NSNotFound,
            range.location >= 0,
            NSMaxRange(range) <= storage.length
        else { return false }
        let substring = storage.attributedSubstring(from: range).string
        return !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Marker range containing `location`, or nil.
    func taskMarkerRange(containingUTF16 location: Int) -> NSRange? {
        rangeOfAttribute(.link, at: location) {
            ($0 as? URL)?.scheme == EditorTaskMarkerLink.scheme
        }
    }

    /// The task marker on the line holding `location`; used to offer an
    /// accessibility toggle action for the task item under the caret.
    func taskMarkerOnLine(containingUTF16Location location: Int) -> NSRange? {
        guard
            let storage = textStorage,
            storage.length > 0,
            location >= 0,
            location < storage.length
        else { return nil }
        let line = lineRange(containingUTF16: NSRange(location: location, length: 0))
        return taskMarkerRanges(in: line).first
    }

    /// Presentable opaque region containing `location`, or nil.
    func opaqueRange(containingUTF16 location: Int) -> NSRange? {
        rangeOfAttribute(.bearobsOpaqueRegion, at: location) { ($0 as? Bool) == true }
            .flatMap { isPresentableOpaqueRange($0) ? $0 : nil }
    }

    /// The UTF-16 line range (including the line terminator) holding `range`.
    func lineRange(containingUTF16 range: NSRange) -> NSRange {
        guard let storage = textStorage, storage.length > 0 else { return range }
        let clamped = NSRange(
            location: max(0, min(range.location, storage.length - 1)),
            length: min(range.length, storage.length)
        )
        return (storage.string as NSString).lineRange(for: clamped)
    }

    /// Focus state for the given selection: markers whose lines the selection
    /// touches, plus the presentable opaque region under the selection head.
    func interactionFocus(forSelection selection: NSRange) -> EditorSurfaceInteractionFocus {
        guard
            let storage = textStorage,
            storage.length > 0,
            selection.location != NSNotFound,
            selection.location >= 0,
            selection.location < storage.length,
            NSMaxRange(selection) <= storage.length
        else { return EditorSurfaceInteractionFocus() }
        var focus = EditorSurfaceInteractionFocus()
        let lineSpan = lineRange(containingUTF16: selection)
        focus.focusedMarkers = taskMarkerRanges(in: lineSpan).filter { marker in
            intersects(selection, line: lineRange(containingUTF16: marker))
        }
        if let opaque = opaqueRange(containingUTF16: selection.location) {
            focus.focusedOpaque = opaque
        }
        return focus
    }

    /// True while the marker's line does not hold the selection, i.e. the
    /// glyphs are hidden and a checkbox is drawn instead.
    func isTaskMarkerSuppressed(_ marker: NSRange) -> Bool {
        !intersects(selection, line: lineRange(containingUTF16: marker))
    }

    /// The checkbox rect for a marker in container coordinates, or nil when
    /// the marker is not laid out.
    func checkboxRect(forTaskMarker marker: NSRange, in container: NSTextContainer) -> NSRect? {
        guard
            let storage = textStorage,
            storage.length > 0,
            marker.location != NSNotFound,
            marker.location >= 0,
            NSMaxRange(marker) <= storage.length
        else { return nil }
        let glyphRange = glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }
        let bounds = boundingRect(forGlyphRange: glyphRange, in: container)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let side = min(Self.checkboxSide, bounds.height)
        return NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
    }

    /// Marker whose checkbox hit area contains the point (container
    /// coordinates), or nil. Used by mouse handling so the drawn checkbox is
    /// the click target even though the storage still holds the bracket
    /// glyphs.
    func taskMarkerRange(at point: NSPoint, in container: NSTextContainer) -> NSRange? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        for marker in taskMarkerRanges(in: NSRange(location: 0, length: storage.length)) {
            guard let box = checkboxRect(forTaskMarker: marker, in: container) else { continue }
            if box.insetBy(
                dx: -Self.checkboxHitPadding,
                dy: -Self.checkboxHitPadding
            ).contains(point) {
                return marker
            }
        }
        return nil
    }

    // MARK: - Drawing

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard
            glyphsToShow.location != NSNotFound,
            glyphsToShow.location + glyphsToShow.length <= max(numberOfGlyphs, 1),
            let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil),
            let storage = textStorage,
            storage.length > 0
        else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        let visibleCharacters = characterRange(
            forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard visibleCharacters.location != NSNotFound else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }

        var suppressed: [(glyphs: NSRange, marker: NSRange)] = []
        for marker in taskMarkerRanges(in: visibleCharacters) where isTaskMarkerSuppressed(marker) {
            let glyphs = glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
            guard glyphs.location != NSNotFound, glyphs.length > 0 else { continue }
            suppressed.append((glyphs, marker))
        }

        // Paint the visible glyphs in complement segments around the markers
        // that are presented as checkboxes.
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for entry in suppressed.sorted(by: { $0.glyphs.location < $1.glyphs.location }) {
            let intersection = NSIntersectionRange(glyphsToShow, entry.glyphs)
            guard intersection.location != NSNotFound else { continue }
            if intersection.location > cursor {
                super.drawGlyphs(
                    forGlyphRange: NSRange(
                        location: cursor, length: intersection.location - cursor),
                    at: origin
                )
            }
            cursor = max(cursor, NSMaxRange(intersection))
        }
        if cursor < end {
            super.drawGlyphs(
                forGlyphRange: NSRange(location: cursor, length: end - cursor),
                at: origin
            )
        }

        // Checkboxes replace the suppressed bracket glyphs; the brackets stay
        // in the storage and remain selectable, accessible, and saved.
        for entry in suppressed {
            guard
                let box = checkboxRect(forTaskMarker: entry.marker, in: container),
                NSMaxRange(entry.marker) <= storage.length
            else { continue }
            let isChecked = storage.attributedSubstring(from: entry.marker).string == "[x]"
            let image = isChecked ? checkboxImages.checked : checkboxImages.unchecked
            image.draw(
                in: box.offsetBy(dx: origin.x, dy: origin.y),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: nil
            )
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard
            glyphsToShow.location != NSNotFound,
            glyphsToShow.location + glyphsToShow.length <= max(numberOfGlyphs, 1),
            let container = textContainer(forGlyphAt: glyphsToShow.location, effectiveRange: nil),
            let storage = textStorage,
            storage.length > 0
        else { return }
        let visibleCharacters = characterRange(
            forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        guard visibleCharacters.location != NSNotFound else { return }

        for opaque in opaqueRanges(in: visibleCharacters) where isPresentableOpaqueRange(opaque) {
            let lineRects = lineFragmentRects(forCharacterRange: opaque, in: container)
            guard !lineRects.isEmpty else { continue }
            let focused = NSLocationInRange(selection.location, opaque)
            if focused {
                let accent = NSColor.controlAccentColor
                accent.withAlphaComponent(0.08).setFill()
                for rect in lineRects {
                    NSBezierPath(
                        roundedRect: rect.insetBy(dx: 0.5, dy: 0.5).offsetBy(
                            dx: origin.x, dy: origin.y
                        ),
                        xRadius: 4,
                        yRadius: 4
                    ).fill()
                }
                accent.withAlphaComponent(0.5).setStroke()
                for rect in lineRects {
                    let border = NSBezierPath(
                        roundedRect: rect.insetBy(dx: 0.5, dy: 0.5).offsetBy(
                            dx: origin.x, dy: origin.y
                        ),
                        xRadius: 4,
                        yRadius: 4
                    )
                    border.lineWidth = 1
                    border.stroke()
                }
            }
            drawCaption(
                above: lineRects[0],
                previousLineMaxY: previousLineMaxY(before: opaque, in: container),
                at: origin
            )
        }
    }

    private func drawCaption(
        above firstLine: NSRect, previousLineMaxY: CGFloat?, at origin: NSPoint
    ) {
        let caption = opaqueCaption
        let captionSize = caption.size()
        guard captionSize.width > 0, captionSize.height > 0 else { return }
        let gap: CGFloat
        if let previousLineMaxY {
            gap = firstLine.minY - previousLineMaxY
        } else {
            gap = firstLine.minY
        }
        guard gap >= captionSize.height + 1 else { return }
        caption.draw(
            in: NSRect(
                x: firstLine.minX,
                y: firstLine.minY - captionSize.height - 1,
                width: captionSize.width,
                height: captionSize.height
            ).offsetBy(dx: origin.x, dy: origin.y)
        )
    }

    private func previousLineMaxY(
        before range: NSRange,
        in container: NSTextContainer
    ) -> CGFloat? {
        guard range.location > 0 else { return nil }
        let glyphIndex = glyphIndexForCharacter(at: range.location - 1)
        guard glyphIndex != NSNotFound, glyphIndex < numberOfGlyphs else { return nil }
        return lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil).maxY
    }

    private func lineFragmentRects(
        forCharacterRange range: NSRange,
        in container: NSTextContainer
    ) -> [NSRect] {
        guard
            let storage = textStorage,
            range.location != NSNotFound,
            range.location >= 0,
            storage.length > 0
        else { return [] }
        var rects: [NSRect] = []
        var characterIndex = range.location
        let end = min(NSMaxRange(range), storage.length)
        while characterIndex < end {
            let glyphIndex = glyphIndexForCharacter(at: characterIndex)
            guard glyphIndex != NSNotFound, glyphIndex < numberOfGlyphs else { break }
            var lineGlyphRange = NSRange()
            rects.append(lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineGlyphRange))
            let lineCharacterRange = characterRange(
                forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            let next = NSMaxRange(lineCharacterRange)
            guard next > characterIndex else { break }
            characterIndex = next
        }
        return rects
    }

    // MARK: - Attribute enumeration

    private func rangesOfAttribute(
        _ key: NSAttributedString.Key,
        in range: NSRange,
        where matches: (Any?) -> Bool
    ) -> [NSRange] {
        guard
            let storage = textStorage,
            storage.length > 0,
            range.location != NSNotFound,
            range.location >= 0,
            NSMaxRange(range) <= storage.length
        else { return [] }
        var result: [NSRange] = []
        storage.enumerateAttribute(key, in: range, options: []) { value, subrange, _ in
            if matches(value) { result.append(subrange) }
        }
        // Forward enumeration yields document order; keep it that way for
        // callers that diff focus state.
        return result.sorted { $0.location < $1.location }
    }

    private func rangeOfAttribute(
        _ key: NSAttributedString.Key,
        at location: Int,
        where matches: (Any?) -> Bool
    ) -> NSRange? {
        guard
            let storage = textStorage,
            storage.length > 0,
            location >= 0,
            location < storage.length
        else { return nil }
        var range = NSRange()
        let value = storage.attribute(
            key,
            at: location,
            longestEffectiveRange: &range,
            in: NSRange(location: 0, length: storage.length)
        )
        guard matches(value), range.location != NSNotFound else { return nil }
        return range
    }

    private func intersects(_ selection: NSRange, line: NSRange) -> Bool {
        if selection.length == 0 {
            return line.location <= selection.location && selection.location < NSMaxRange(line)
        }
        return NSIntersectionRange(selection, line).location != NSNotFound
    }
}
