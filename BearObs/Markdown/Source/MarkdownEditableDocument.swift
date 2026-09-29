import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public enum MarkdownEditNodeKind: Equatable, Sendable {
    case heading(level: Int)
    case paragraph
    case listItem
    case quote
    case codeBlock
    case taskItem
    case opaque
}

public enum MarkdownEditableSpanRole: Equatable, Sendable {
    case text
    case taskMarker
}

public struct MarkdownEditableSpan: Equatable, Sendable {
    public let role: MarkdownEditableSpanRole
    public let range: Range<Int>
    public let expectedOriginal: Data

    public init(
        role: MarkdownEditableSpanRole,
        range: Range<Int>,
        expectedOriginal: Data
    ) {
        self.role = role
        self.range = range
        self.expectedOriginal = expectedOriginal
    }

    public var sourceRange: Range<Int> { range }
    public var originalData: Data { expectedOriginal }
}

public struct MarkdownSourceNode: Equatable, Sendable {
    public let kind: MarkdownEditNodeKind
    public let sourceRange: Range<Int>
    public let editableSpans: [MarkdownEditableSpan]
    public let isOpaque: Bool

    public init(
        kind: MarkdownEditNodeKind,
        sourceRange: Range<Int>,
        editableSpans: [MarkdownEditableSpan],
        isOpaque: Bool
    ) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.editableSpans = editableSpans
        self.isOpaque = isOpaque
    }

    public var range: Range<Int> { sourceRange }
}

public struct MarkdownSourceMap: Equatable, Sendable {
    public let baselineHash: ContentHash
    public let nodes: [MarkdownSourceNode]

    public init(baselineHash: ContentHash, nodes: [MarkdownSourceNode]) {
        self.baselineHash = baselineHash
        self.nodes = nodes
    }

    public var editableSpans: [MarkdownEditableSpan] {
        nodes.flatMap(\.editableSpans)
    }
}

public struct MarkdownSourceSnapshot: Equatable, Sendable {
    public let data: Data
    public let contentHash: ContentHash
    public let sourceInfo: MarkdownSourceInfo
    public let text: String
    public let sourceMap: MarkdownSourceMap

    public init(
        data: Data,
        contentHash: ContentHash,
        sourceInfo: MarkdownSourceInfo,
        text: String,
        sourceMap: MarkdownSourceMap
    ) {
        self.data = data
        self.contentHash = contentHash
        self.sourceInfo = sourceInfo
        self.text = text
        self.sourceMap = sourceMap
    }

    public var rawData: Data { data }
    public var visibleData: Data {
        sourceInfo.hasUTF8BOM ? Data(data.dropFirst(3)) : data
    }
}

public enum MarkdownSourceMapError: Error, Equatable, Sendable {
    case invalidUTF8
    case invalidSourceMap
}

/// Syntax overlay for the text currently shown in the editor. Ranges are UTF-8
/// half-open intervals relative to the draft text itself, not to the original
/// file bytes.
public struct MarkdownDraftSyntaxOverlay: Equatable, Sendable {
    public let opaqueRanges: [Range<Int>]
    public let taskMarkerRanges: [Range<Int>]

    public init(opaqueRanges: [Range<Int>], taskMarkerRanges: [Range<Int>]) {
        self.opaqueRanges = opaqueRanges
        self.taskMarkerRanges = taskMarkerRanges
    }
}

public enum MarkdownDraftSyntaxResolver {
    /// Reuses the snapshot's ranges while the draft is unedited and re-parses the
    /// draft itself once editing begins, so opaque regions and task markers keep
    /// tracking the displayed text instead of stale baseline bytes.
    public static func resolve(
        text: String,
        snapshot: MarkdownSourceSnapshot?
    ) -> MarkdownDraftSyntaxOverlay? {
        guard
            let projection = MarkdownEditorProjectionBuilder.build(
                text: text,
                snapshot: snapshot
            )
        else {
            return nil
        }
        var opaqueRanges: [Range<Int>] = []
        var taskMarkerRanges: [Range<Int>] = []
        for run in projection.runs {
            switch run.token {
            case .opaque: opaqueRanges.append(run.range)
            case .taskMarker: taskMarkerRanges.append(run.range)
            case .heading, .listItem, .quote, .codeBlock: break
            }
        }
        return MarkdownDraftSyntaxOverlay(
            opaqueRanges: opaqueRanges,
            taskMarkerRanges: taskMarkerRanges
        )
    }
}
