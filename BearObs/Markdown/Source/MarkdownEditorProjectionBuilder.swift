import Foundation

/// Presentation token for one span of the draft text. Tokens carry values
/// only; mapping them onto fonts, colors, and paragraph styles stays in the
/// platform adapter so this module never imports SwiftUI or AppKit.
public enum MarkdownEditorStyleToken: Equatable, Sendable {
    case heading(level: Int)
    case listItem
    case quote
    case codeBlock
    case opaque
    case taskMarker
}

public struct MarkdownEditorStyleRun: Equatable, Sendable {
    public let range: Range<Int>
    public let token: MarkdownEditorStyleToken

    public init(range: Range<Int>, token: MarkdownEditorStyleToken) {
        self.range = range
        self.token = token
    }
}

/// Projection of the text currently shown in the editor. Ranges are UTF-8
/// half-open intervals relative to the visible draft text itself, not to the
/// original file bytes. Plain paragraphs carry the base style and produce no
/// run.
public struct MarkdownEditorProjection: Equatable, Sendable {
    public let text: String
    public let runs: [MarkdownEditorStyleRun]

    public init(text: String, runs: [MarkdownEditorStyleRun]) {
        self.text = text
        self.runs = runs
    }
}

/// Builds the editor projection from the source map. Reuses the snapshot's
/// ranges while the draft is unedited and re-parses the draft itself once
/// editing begins, so runs keep tracking the displayed text instead of stale
/// baseline bytes. The projection has no save interface and never modifies the
/// input.
public enum MarkdownEditorProjectionBuilder {
    private static let utf8BOMLength = 3

    /// Returns nil only when the draft cannot be parsed; every valid UTF-8
    /// input yields a safe projection or an explicit failure, never a crash.
    public static func build(
        text: String,
        snapshot: MarkdownSourceSnapshot?
    ) -> MarkdownEditorProjection? {
        let byteShift: Int
        let nodes: [MarkdownSourceNode]
        if let snapshot, snapshot.text == text {
            byteShift = snapshot.sourceInfo.hasUTF8BOM ? utf8BOMLength : 0
            nodes = snapshot.sourceMap.nodes
        } else {
            guard let draft = try? MarkdownSourceMapParser.parse(Data(text.utf8)) else {
                return nil
            }
            byteShift = 0
            nodes = draft.sourceMap.nodes
        }
        return MarkdownEditorProjection(text: text, runs: runs(from: nodes, byteShift: byteShift))
    }

    private static func runs(
        from nodes: [MarkdownSourceNode],
        byteShift: Int
    ) -> [MarkdownEditorStyleRun] {
        var runs: [MarkdownEditorStyleRun] = []
        for node in nodes {
            if node.isOpaque {
                append(node.sourceRange, token: .opaque, byteShift: byteShift, to: &runs)
                continue
            }
            if let token = styleToken(for: node.kind) {
                append(node.sourceRange, token: token, byteShift: byteShift, to: &runs)
            }
            for span in node.editableSpans where span.role == .taskMarker {
                append(span.range, token: .taskMarker, byteShift: byteShift, to: &runs)
            }
        }
        return runs
    }

    private static func styleToken(for kind: MarkdownEditNodeKind) -> MarkdownEditorStyleToken? {
        switch kind {
        case .heading(let level): .heading(level: level)
        case .listItem: .listItem
        case .quote: .quote
        case .codeBlock: .codeBlock
        case .taskItem: .listItem
        case .paragraph, .opaque: nil
        }
    }

    private static func append(
        _ range: Range<Int>,
        token: MarkdownEditorStyleToken,
        byteShift: Int,
        to runs: inout [MarkdownEditorStyleRun]
    ) {
        // A node can straddle the BOM boundary (the parser merges the BOM with
        // the following opaque block); clamp it to the visible draft bytes.
        let shifted = (max(range.lowerBound - byteShift, 0))..<(range.upperBound - byteShift)
        guard !shifted.isEmpty else { return }
        runs.append(MarkdownEditorStyleRun(range: shifted, token: token))
    }
}
