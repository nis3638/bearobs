import Foundation
import Markdown

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

/// One top-level rendered block together with its provenance in the original
/// file bytes. `id` is the block's source start, so the reader can anchor
/// scrolling in source coordinates instead of array offsets (REQ-002 6.1).
/// Ranges are UTF-8 half-open intervals over the full file data, BOM and
/// frontmatter included, matching the wiki link occurrence coordinates.
public struct MarkdownRenderBlockEntry: Equatable, Sendable, Identifiable {
    public let id: Int
    public let sourceRange: Range<Int>
    public let block: MarkdownRenderBlock

    public init(sourceRange: Range<Int>, block: MarkdownRenderBlock) {
        id = sourceRange.lowerBound
        self.sourceRange = sourceRange
        self.block = block
    }
}

public struct MarkdownRenderDocument: Equatable, Sendable {
    public let title: String
    /// The canonical block list. Blocks without provenance (tests, previews)
    /// carry empty ranges, which never act as scroll anchors.
    public let entries: [MarkdownRenderBlockEntry]

    public init(title: String = "", entries: [MarkdownRenderBlockEntry]) {
        self.title = title
        self.entries = entries
    }

    public init(title: String = "", blocks: [MarkdownRenderBlock]) {
        self.init(
            title: title,
            entries: blocks.enumerated().map { index, block in
                MarkdownRenderBlockEntry(sourceRange: index..<index, block: block)
            }
        )
    }

    public var blocks: [MarkdownRenderBlock] { entries.map(\.block) }
}

public indirect enum MarkdownRenderBlock: Equatable, Sendable {
    case heading(level: Int, content: [MarkdownRenderInline])
    case paragraph([MarkdownRenderInline])
    case quote([MarkdownRenderBlock])
    case unorderedList([MarkdownRenderListItem])
    case orderedList(start: Int, items: [MarkdownRenderListItem])
    case codeBlock(language: String?, code: String)
    case thematicBreak
    case fallback(String)
}

public struct MarkdownRenderListItem: Equatable, Sendable {
    public let task: MarkdownRenderTask?
    public let blocks: [MarkdownRenderBlock]

    public init(task: MarkdownRenderTask?, blocks: [MarkdownRenderBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

public enum MarkdownRenderTask: Equatable, Sendable {
    case checked
    case unchecked
}

public indirect enum MarkdownRenderInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownRenderInline])
    case strong([MarkdownRenderInline])
    case strikethrough([MarkdownRenderInline])
    case code(String)
    case link(content: [MarkdownRenderInline], destination: URL?)
    case image(alternativeText: String)
    case wikiLink(label: String, target: String, resolution: MarkdownWikiLinkResolution)
    case lineBreak
}

public enum MarkdownWikiLinkResolution: Equatable, Sendable {
    case unresolved
    case resolved(VaultPath)
    case missing
    case ambiguous
}

public struct MarkdownWikiLinkDestination: Equatable, Sendable {
    public let sourceRange: Range<Int>
    public let resolution: MarkdownWikiLinkResolution

    public init(sourceRange: Range<Int>, resolution: MarkdownWikiLinkResolution) {
        self.sourceRange = sourceRange
        self.resolution = resolution
    }
}

public enum MarkdownReaderRenderer {
    public static func render(
        _ note: ParsedNote,
        wikiLinks: [MarkdownWikiLinkDestination] = []
    ) -> MarkdownRenderDocument {
        let context = WikiLinkRenderContext(note: note, destinations: wikiLinks)
        let entries = blockEntries(
            in: note.ast.document,
            context: context,
            inheritedRange: context.absoluteByteRange(note.ast.document.range)
        )
        return MarkdownRenderDocument(title: note.title, entries: entries)
    }
}

extension MarkdownReaderRenderer {
    /// Top-level blocks become entries so the reader can anchor scrolling in
    /// source coordinates. A node whose own range cannot be mapped inherits
    /// the nearest mapped ancestor range; a block with no mapped ancestor
    /// carries an empty range and never becomes a restore anchor — a guessed
    /// write range is never invented (REQ-002 6.1).
    private static func blockEntries(
        in markup: Markup,
        context: WikiLinkRenderContext,
        inheritedRange: Range<Int>?
    ) -> [MarkdownRenderBlockEntry] {
        let ownRange = context.absoluteByteRange(markup.range) ?? inheritedRange
        return markup.children.flatMap { child in
            blockEntries(child, context: context, inheritedRange: ownRange)
        }
    }

    private static func blockEntries(
        _ markup: Markup,
        context: WikiLinkRenderContext,
        inheritedRange: Range<Int>?
    ) -> [MarkdownRenderBlockEntry] {
        let ownRange = context.absoluteByteRange(markup.range) ?? inheritedRange
        switch markup {
        case let heading as Heading:
            return [
                entry(
                    ownRange,
                    .heading(level: heading.level, content: inline(in: heading, context: context))
                )
            ]
        case let paragraph as Paragraph:
            return [entry(ownRange, .paragraph(inline(in: paragraph, context: context)))]
        case let quote as BlockQuote:
            return [entry(ownRange, .quote(blocks(in: quote, context: context)))]
        case let list as UnorderedList:
            return [
                entry(
                    ownRange,
                    .unorderedList(list.children.compactMap { listItem($0, context: context) })
                )
            ]
        case let list as OrderedList:
            return [
                entry(
                    ownRange,
                    .orderedList(
                        start: Int(list.startIndex),
                        items: list.children.compactMap { listItem($0, context: context) }
                    )
                )
            ]
        case let code as CodeBlock:
            return [entry(ownRange, .codeBlock(language: code.language, code: code.code))]
        case is ThematicBreak:
            return [entry(ownRange, .thematicBreak)]
        case is HTMLBlock:
            return [entry(ownRange, .fallback(fallbackSource(markup)))]
        default:
            return markup.childCount > 0
                ? blockEntries(in: markup, context: context, inheritedRange: ownRange)
                : [entry(ownRange, .fallback(fallbackSource(markup)))]
        }
    }

    private static func entry(
        _ range: Range<Int>?,
        _ block: MarkdownRenderBlock
    ) -> MarkdownRenderBlockEntry {
        MarkdownRenderBlockEntry(sourceRange: range ?? 0..<0, block: block)
    }

    private static func blocks(
        in markup: Markup,
        context: WikiLinkRenderContext
    ) -> [MarkdownRenderBlock] {
        markup.children.flatMap { child in block(child, context: context) }
    }

    private static func block(
        _ markup: Markup,
        context: WikiLinkRenderContext
    ) -> [MarkdownRenderBlock] {
        blockEntries(markup, context: context, inheritedRange: nil).map(\.block)
    }

    private static func listItem(
        _ markup: Markup,
        context: WikiLinkRenderContext
    ) -> MarkdownRenderListItem? {
        guard let item = markup as? ListItem else { return nil }
        let task: MarkdownRenderTask?
        switch item.checkbox {
        case .checked: task = .checked
        case .unchecked: task = .unchecked
        case nil: task = nil
        }
        return MarkdownRenderListItem(task: task, blocks: blocks(in: item, context: context))
    }

    private static func inline(
        in markup: Markup,
        context: WikiLinkRenderContext
    ) -> [MarkdownRenderInline] {
        markup.children.flatMap { inlineNode($0, context: context) }
    }

    private static func inlineNode(
        _ markup: Markup,
        context: WikiLinkRenderContext
    ) -> [MarkdownRenderInline] {
        switch markup {
        case let text as Text:
            context.render(text)
        case let emphasis as Emphasis:
            [.emphasis(inline(in: emphasis, context: context))]
        case let strong as Strong:
            [.strong(inline(in: strong, context: context))]
        case let strikethrough as Strikethrough:
            [.strikethrough(inline(in: strikethrough, context: context))]
        case let code as InlineCode:
            [.code(code.code)]
        case let link as Link:
            [
                .link(
                    content: inline(in: link, context: context),
                    destination: safeExternalURL(link.destination)
                )
            ]
        case let image as Image:
            [.image(alternativeText: plainText(in: image))]
        case is SoftBreak:
            [.text(" ")]
        case is LineBreak:
            [.lineBreak]
        case is InlineHTML:
            [.text(fallbackSource(markup))]
        default:
            markup.childCount > 0
                ? inline(in: markup, context: context) : [.text(fallbackSource(markup))]
        }
    }

    private static func plainText(in markup: Markup) -> String {
        markup.children.map { child in
            if let text = child as? Text { return text.string }
            return plainText(in: child)
        }.joined()
    }

    private static func safeExternalURL(_ source: String?) -> URL? {
        guard
            let source,
            let url = URL(string: source),
            url.user == nil,
            url.password == nil,
            let scheme = url.scheme?.lowercased()
        else {
            return nil
        }
        switch scheme {
        case "http", "https":
            return url.host == nil ? nil : url
        case "mailto":
            return url.path.isEmpty ? nil : url
        default:
            return nil
        }
    }

    private static func fallbackSource(_ markup: Markup) -> String {
        markup.format().trimmingCharacters(in: .newlines)
    }
}

private struct WikiLinkRenderContext {
    private let body: ReaderBodySource
    private let bodyRange: Range<Int>
    private let occurrences: [WikiLink]
    private let destinations: [Int: MarkdownWikiLinkDestination]

    init(note: ParsedNote, destinations: [MarkdownWikiLinkDestination]) {
        body = ReaderBodySource(note.ast.bodyData)
        bodyRange = note.ast.bodyRange
        occurrences = note.syntax.wikiLinks
        self.destinations = Dictionary(
            destinations.map { ($0.sourceRange.lowerBound, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Maps a swift-markdown source range to absolute file byte coordinates,
    /// BOM and frontmatter included. This is the same coordinate space the
    /// wiki link occurrences use, so reader anchors and editor drafts can be
    /// reconciled through the source snapshot's BOM shift alone.
    func absoluteByteRange(_ sourceRange: SourceRange?) -> Range<Int>? {
        guard let relative = body.byteRange(sourceRange) else { return nil }
        let lower = bodyRange.lowerBound + relative.lowerBound
        let upper = bodyRange.lowerBound + relative.upperBound
        return lower..<upper
    }

    func render(_ text: Text) -> [MarkdownRenderInline] {
        guard
            !destinations.isEmpty,
            let relativeRange = body.byteRange(text.range)
        else {
            return [.text(text.string)]
        }
        let lowerBound = bodyRange.lowerBound + relativeRange.lowerBound
        let upperBound = bodyRange.lowerBound + relativeRange.upperBound
        let absoluteRange = lowerBound..<upperBound
        let links = occurrences.filter { occurrence in
            absoluteRange.contains(occurrence.sourceRange.lowerBound)
                && occurrence.sourceRange.upperBound <= absoluteRange.upperBound
                && destinations[occurrence.sourceRange.lowerBound]?.sourceRange
                    == occurrence.sourceRange
        }
        guard !links.isEmpty else { return [.text(text.string)] }

        var rendered: [MarkdownRenderInline] = []
        var cursor = text.string.startIndex
        for occurrence in links.sorted(by: { $0.sourceRange.lowerBound < $1.sourceRange.lowerBound }
        ) {
            let lowerOffset = occurrence.sourceRange.lowerBound - absoluteRange.lowerBound
            let upperOffset = occurrence.sourceRange.upperBound - absoluteRange.lowerBound
            guard
                let lowerUTF8 = text.string.utf8.index(
                    text.string.utf8.startIndex,
                    offsetBy: lowerOffset,
                    limitedBy: text.string.utf8.endIndex
                ),
                let upperUTF8 = text.string.utf8.index(
                    text.string.utf8.startIndex,
                    offsetBy: upperOffset,
                    limitedBy: text.string.utf8.endIndex
                ),
                let lower = String.Index(lowerUTF8, within: text.string),
                let upper = String.Index(upperUTF8, within: text.string),
                cursor <= lower,
                String(text.string[lower..<upper]) == occurrence.source,
                let destination = destinations[occurrence.sourceRange.lowerBound]
            else {
                return [.text(text.string)]
            }
            if cursor < lower {
                rendered.append(.text(String(text.string[cursor..<lower])))
            }
            rendered.append(
                .wikiLink(
                    label: occurrence.alias ?? occurrence.target,
                    target: occurrence.target,
                    resolution: destination.resolution
                )
            )
            cursor = upper
        }
        if cursor < text.string.endIndex {
            rendered.append(.text(String(text.string[cursor...])))
        }
        return rendered
    }
}

private struct ReaderBodySource {
    private let byteCount: Int
    private let lineStarts: [Int]

    init(_ data: Data) {
        let bytes = Array(data)
        byteCount = bytes.count
        lineStarts = bytes.indices.reduce(into: [0]) { starts, index in
            if bytes[index] == 0x0A {
                starts.append(index + 1)
            }
        }
    }

    func byteRange(_ sourceRange: SourceRange?) -> Range<Int>? {
        guard
            let sourceRange,
            let lower = byteOffset(sourceRange.lowerBound),
            let upper = byteOffset(sourceRange.upperBound),
            lower <= upper,
            upper <= byteCount
        else {
            return nil
        }
        return lower..<upper
    }

    private func byteOffset(_ location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineStarts.indices.contains(lineIndex), location.column > 0 else {
            return nil
        }
        return lineStarts[lineIndex] + location.column - 1
    }
}
