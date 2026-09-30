import SwiftUI

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
#endif

/// Continuous record of where the reader viewport is, expressed in original
/// file byte coordinates so entering edit mode can restore the same content
/// (REQ-002 6.1). The reader freezes the latest value when the user taps
/// Edit; the value itself never outlives the note path it was recorded for.
struct ReaderViewportSnapshot: Equatable, Sendable {
    let path: VaultPath
    /// UTF-8 byte offset of the topmost visible block's source start in the
    /// original file, BOM and frontmatter included.
    let anchorSourceOffset: Int
    /// Full source range of that block in the original file bytes.
    let blockSourceRange: Range<Int>
    /// Block top relative to the viewport top, in points. Negative when the
    /// block spans the viewport's top edge.
    let verticalOffset: Double
}

/// Frame of one top-level reader block inside the reader scroll coordinate
/// space. That space is the scroll view's own bounds, so the viewport top
/// edge is always y = 0 and frames move with the content while scrolling.
struct ReaderBlockFrame: Equatable, Sendable {
    let entryIndex: Int
    let minY: CGFloat
    let maxY: CGFloat
}

struct ReaderBlockFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [ReaderBlockFrame] = []

    static func reduce(value: inout [ReaderBlockFrame], nextValue: () -> [ReaderBlockFrame]) {
        value.append(contentsOf: nextValue())
    }
}

/// Reports one top-level block's frame into the viewport preference. Nested
/// blocks render without anchors: only top-level entries are scroll anchors.
struct ReaderBlockAnchorView<Content: View>: View {
    let entryIndex: Int
    @ViewBuilder let content: Content

    var body: some View {
        content.background {
            GeometryReader { proxy in
                let frame = proxy.frame(
                    in: .named(ReaderViewportTracker.scrollCoordinateSpace)
                )
                Color.clear.preference(
                    key: ReaderBlockFramesPreferenceKey.self,
                    value: [
                        ReaderBlockFrame(
                            entryIndex: entryIndex,
                            minY: frame.minY,
                            maxY: frame.maxY
                        )
                    ]
                )
            }
        }
    }
}

/// Decides which block the reader's viewport top edge is on and converts
/// between visible-block geometry and source coordinates. The SwiftUI glue
/// (anchors, preference collection) stays dumb; every decision is a pure
/// function here so top/middle/tail behaviour is testable without pixel or
/// timing guesses (REQ-002 P5).
enum ReaderViewportTracker {
    static let scrollCoordinateSpace = "reader-scroll"

    /// The block the viewport's top edge is on: the first block that is not
    /// entirely above the edge. LazyVStack realizes only the blocks near the
    /// viewport, so frames arrive sparse and unordered — the topmost visible
    /// block is always among them.
    static func topmostVisibleFrame(_ frames: [ReaderBlockFrame]) -> ReaderBlockFrame? {
        frames
            .filter { $0.maxY > 0 }
            .min { lhs, rhs in
                lhs.minY == rhs.minY ? lhs.maxY < rhs.maxY : lhs.minY < rhs.minY
            }
    }

    /// Freezes the current viewport as a source-coordinate snapshot. Returns
    /// nil when nothing is realized or the topmost block has no proven source
    /// range: without a real anchor the editor opens at the top rather than
    /// guessing one.
    static func snapshot(
        frames: [ReaderBlockFrame],
        entries: [MarkdownRenderBlockEntry],
        path: VaultPath
    ) -> ReaderViewportSnapshot? {
        guard let frame = topmostVisibleFrame(frames) else { return nil }
        guard entries.indices.contains(frame.entryIndex) else { return nil }
        let sourceRange = entries[frame.entryIndex].sourceRange
        guard !sourceRange.isEmpty else { return nil }
        return ReaderViewportSnapshot(
            path: path,
            anchorSourceOffset: sourceRange.lowerBound,
            blockSourceRange: sourceRange,
            verticalOffset: Double(frame.minY)
        )
    }

    /// Restore target for the editor → reader direction: the index of the
    /// entry containing `sourceOffset`, or the nearest block above it when the
    /// offset lands in inter-block whitespace. Nil when the offset precedes
    /// every block (frontmatter, empty document) — the reader then stays at
    /// the top, which shows the same content.
    static func entryIndex(
        containing sourceOffset: Int,
        in entries: [MarkdownRenderBlockEntry]
    ) -> Int? {
        var result: Int?
        for (index, entry) in entries.enumerated()
        where !entry.sourceRange.isEmpty && entry.sourceRange.lowerBound <= sourceOffset {
            result = index
        }
        return result
    }
}
