import CryptoKit
import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public enum MarkdownSourceMapParser {
    public static func parse(
        _ data: Data,
        contentHash: ContentHash,
        sourceInfo: MarkdownSourceInfo
    ) throws -> MarkdownSourceSnapshot {
        guard String(data: data, encoding: .utf8) != nil else {
            throw MarkdownSourceMapError.invalidUTF8
        }

        guard !sourceInfo.hasUTF8BOM || data.starts(with: utf8BOM) else {
            throw MarkdownSourceMapError.invalidSourceMap
        }
        let nodes = parseNodes(
            in: data,
            treatsLeadingBOMAsMetadata: sourceInfo.hasUTF8BOM
        )
        guard validate(nodes, in: data) else {
            throw MarkdownSourceMapError.invalidSourceMap
        }
        let visible = sourceInfo.hasUTF8BOM ? Data(data.dropFirst(3)) : data
        let text = String(decoding: visible, as: UTF8.self)
        return MarkdownSourceSnapshot(
            data: data,
            contentHash: contentHash,
            sourceInfo: sourceInfo,
            text: text,
            sourceMap: MarkdownSourceMap(
                baselineHash: contentHash,
                nodes: nodes
            )
        )
    }

    public static func parse(
        _ data: Data,
        contentHash: ContentHash
    ) throws -> MarkdownSourceSnapshot {
        try parse(
            data,
            contentHash: contentHash,
            sourceInfo: sourceInformation(for: data)
        )
    }

    public static func parse(_ data: Data) throws -> MarkdownSourceSnapshot {
        guard String(data: data, encoding: .utf8) != nil else {
            throw MarkdownSourceMapError.invalidUTF8
        }
        var hasher = SHA256()
        hasher.update(data: data)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return try parse(data, contentHash: ContentHash(hex: hex))
    }
}

extension MarkdownSourceMapParser {
    private struct SourceLine {
        let contentRange: Range<Int>
        let fullRange: Range<Int>
    }

    private struct Fence {
        let marker: UInt8
        let count: Int
        let hasInfoString: Bool
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    private static func parseNodes(
        in data: Data,
        treatsLeadingBOMAsMetadata: Bool
    ) -> [MarkdownSourceNode] {
        let bytes = Array(data)
        let contentStart = treatsLeadingBOMAsMetadata ? utf8BOM.count : 0
        let lines = scanLines(bytes, from: contentStart)
        var nodes: [MarkdownSourceNode] = []
        var lineIndex = 0

        if contentStart > 0 {
            appendOpaque(0..<contentStart, to: &nodes)
        }
        if let first = lines.first, isFrontmatterDelimiter(first, bytes: bytes) {
            guard
                let closing = lines.dropFirst().firstIndex(where: {
                    isFrontmatterDelimiter($0, bytes: bytes)
                })
            else {
                return [opaqueNode(0..<data.count)]
            }
            appendOpaque(
                contentStart..<lines[closing].fullRange.upperBound,
                to: &nodes
            )
            lineIndex = closing + 1
        }

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let content = Array(bytes[line.contentRange])
            let nextContent: [UInt8]? =
                lineIndex + 1 < lines.count
                ? Array(bytes[lines[lineIndex + 1].contentRange])
                : nil

            if let fence = openingFence(content) {
                let blockStart = line.fullRange.lowerBound
                var blockEnd = line.fullRange.upperBound
                lineIndex += 1
                while lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    blockEnd = candidate.fullRange.upperBound
                    lineIndex += 1
                    if isClosingFence(
                        Array(bytes[candidate.contentRange]),
                        matching: fence
                    ) {
                        break
                    }
                }
                appendFenced(blockStart..<blockEnd, hasInfoString: fence.hasInfoString, to: &nodes)
                continue
            }

            if contains(content, ascii: "<!--") {
                let blockStart = line.fullRange.lowerBound
                var blockEnd = line.fullRange.upperBound
                var closed = contains(content, ascii: "-->")
                lineIndex += 1
                while !closed, lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    let candidateContent = Array(bytes[candidate.contentRange])
                    blockEnd = candidate.fullRange.upperBound
                    closed = contains(candidateContent, ascii: "-->")
                    lineIndex += 1
                }
                appendOpaque(blockStart..<blockEnd, to: &nodes)
                continue
            }

            if contains(content, ascii: "%%") {
                let blockStart = line.fullRange.lowerBound
                var blockEnd = line.fullRange.upperBound
                var isOpen = occurrences(of: "%%", in: content).isMultiple(of: 2) == false
                lineIndex += 1
                while isOpen, lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    let candidateContent = Array(bytes[candidate.contentRange])
                    blockEnd = candidate.fullRange.upperBound
                    if !occurrences(of: "%%", in: candidateContent).isMultiple(of: 2) {
                        isOpen.toggle()
                    }
                    lineIndex += 1
                }
                appendOpaque(blockStart..<blockEnd, to: &nodes)
                continue
            }

            if isMathBlockDelimiter(content) {
                let blockStart = line.fullRange.lowerBound
                var blockEnd = line.fullRange.upperBound
                lineIndex += 1
                while lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    blockEnd = candidate.fullRange.upperBound
                    lineIndex += 1
                    if isMathBlockDelimiter(Array(bytes[candidate.contentRange])) {
                        break
                    }
                }
                appendOpaque(blockStart..<blockEnd, to: &nodes)
                continue
            }

            if let htmlTag = openingHTMLBlockTag(content) {
                let blockStart = line.fullRange.lowerBound
                var blockEnd = line.fullRange.upperBound
                var depth = htmlTagBalance(htmlTag, in: content)
                lineIndex += 1
                while depth > 0, lineIndex < lines.count {
                    let candidate = lines[lineIndex]
                    let candidateContent = Array(bytes[candidate.contentRange])
                    blockEnd = candidate.fullRange.upperBound
                    depth += htmlTagBalance(htmlTag, in: candidateContent)
                    lineIndex += 1
                }
                appendOpaque(blockStart..<blockEnd, to: &nodes)
                continue
            }

            if isIndentedCode(content) {
                appendOpaque(line.fullRange, to: &nodes)
                lineIndex += 1
                continue
            }

            if let markerRange = taskMarkerRange(
                in: content, baseOffset: line.contentRange.lowerBound)
            {
                nodes.append(
                    sourceNode(
                        kind: .taskItem,
                        sourceRange: line.fullRange,
                        spanRole: .taskMarker,
                        spanRange: markerRange,
                        data: data
                    )
                )
            } else if let (level, textRange) = headingTextRange(
                in: content,
                baseOffset: line.contentRange.lowerBound
            ), isSafePlainText(Array(bytes[textRange])) {
                nodes.append(
                    sourceNode(
                        kind: .heading(level: level),
                        sourceRange: line.fullRange,
                        spanRole: .text,
                        spanRange: textRange,
                        data: data
                    )
                )
            } else if let textRange = listItemTextRange(
                in: content,
                baseOffset: line.contentRange.lowerBound
            ), isStructurableContent(Array(bytes[textRange]), next: nextContent) {
                nodes.append(
                    markerNode(
                        kind: .listItem,
                        sourceRange: line.fullRange,
                        textRange: textRange,
                        data: data
                    )
                )
            } else if let textRange = quoteTextRange(
                in: content,
                baseOffset: line.contentRange.lowerBound
            ), isStructurableContent(Array(bytes[textRange]), next: nextContent) {
                nodes.append(
                    markerNode(
                        kind: .quote,
                        sourceRange: line.fullRange,
                        textRange: textRange,
                        data: data
                    )
                )
            } else if isPlainParagraph(content, next: nextContent) {
                nodes.append(
                    sourceNode(
                        kind: .paragraph,
                        sourceRange: line.fullRange,
                        spanRole: .text,
                        spanRange: line.contentRange,
                        data: data
                    )
                )
            } else {
                appendOpaque(line.fullRange, to: &nodes)
            }
            lineIndex += 1
        }

        return nodes
    }

    private static func sourceNode(
        kind: MarkdownEditNodeKind,
        sourceRange: Range<Int>,
        spanRole: MarkdownEditableSpanRole,
        spanRange: Range<Int>,
        data: Data
    ) -> MarkdownSourceNode {
        MarkdownSourceNode(
            kind: kind,
            sourceRange: sourceRange,
            editableSpans: [
                MarkdownEditableSpan(
                    role: spanRole,
                    range: spanRange,
                    expectedOriginal: data.subdata(in: spanRange)
                )
            ],
            isOpaque: false
        )
    }

    /// Marker-prefixed lines keep the marker out of the editable span. Empty
    /// content (`>` or `- ` alone) still forms a node so presentation stays
    /// stable, but publishes no span because there is nothing to edit.
    private static func markerNode(
        kind: MarkdownEditNodeKind,
        sourceRange: Range<Int>,
        textRange: Range<Int>,
        data: Data
    ) -> MarkdownSourceNode {
        let spans =
            textRange.isEmpty
            ? []
            : [
                MarkdownEditableSpan(
                    role: .text,
                    range: textRange,
                    expectedOriginal: data.subdata(in: textRange)
                )
            ]
        return MarkdownSourceNode(
            kind: kind,
            sourceRange: sourceRange,
            editableSpans: spans,
            isOpaque: false
        )
    }

    private static func appendFenced(
        _ range: Range<Int>,
        hasInfoString: Bool,
        to nodes: inout [MarkdownSourceNode]
    ) {
        // A bare fence has provable boundaries; any info string may be a plugin
        // block (Dataview, Query, …) and keeps degrading to opaque.
        guard !hasInfoString else {
            appendOpaque(range, to: &nodes)
            return
        }
        nodes.append(
            MarkdownSourceNode(
                kind: .codeBlock,
                sourceRange: range,
                editableSpans: [],
                isOpaque: false
            )
        )
    }

    private static func opaqueNode(_ range: Range<Int>) -> MarkdownSourceNode {
        MarkdownSourceNode(
            kind: .opaque,
            sourceRange: range,
            editableSpans: [],
            isOpaque: true
        )
    }

    private static func appendOpaque(
        _ range: Range<Int>,
        to nodes: inout [MarkdownSourceNode]
    ) {
        guard !range.isEmpty else { return }
        if let last = nodes.last,
            last.isOpaque,
            last.sourceRange.upperBound == range.lowerBound
        {
            nodes[nodes.count - 1] = opaqueNode(last.sourceRange.lowerBound..<range.upperBound)
        } else {
            nodes.append(opaqueNode(range))
        }
    }
}

extension MarkdownSourceMapParser {
    private static func scanLines(_ bytes: [UInt8], from start: Int) -> [SourceLine] {
        guard start < bytes.count else { return [] }
        var result: [SourceLine] = []
        var offset = start
        while offset < bytes.count {
            var end = offset
            while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D {
                end += 1
            }
            var next = end
            if next < bytes.count {
                if bytes[next] == 0x0D,
                    next + 1 < bytes.count,
                    bytes[next + 1] == 0x0A
                {
                    next += 2
                } else {
                    next += 1
                }
            }
            result.append(
                SourceLine(contentRange: offset..<end, fullRange: offset..<next)
            )
            offset = next
        }
        return result
    }

    private static func isFrontmatterDelimiter(
        _ line: SourceLine,
        bytes: [UInt8]
    ) -> Bool {
        bytes[line.contentRange].elementsEqual("---".utf8)
    }

    private static func openingFence(_ content: [UInt8]) -> Fence? {
        var index = 0
        while index < content.count, index < 3, content[index] == 0x20 {
            index += 1
        }
        guard index < content.count, content[index] == 0x60 || content[index] == 0x7E else {
            return nil
        }
        let marker = content[index]
        let start = index
        while index < content.count, content[index] == marker { index += 1 }
        guard index - start >= 3 else { return nil }
        var infoIndex = index
        while infoIndex < content.count,
            content[infoIndex] == 0x20 || content[infoIndex] == 0x09
        {
            infoIndex += 1
        }
        return Fence(
            marker: marker,
            count: index - start,
            hasInfoString: infoIndex < content.count
        )
    }

    private static func isClosingFence(_ content: [UInt8], matching fence: Fence) -> Bool {
        var index = 0
        while index < content.count, index < 3, content[index] == 0x20 {
            index += 1
        }
        let markerStart = index
        while index < content.count, content[index] == fence.marker { index += 1 }
        guard index - markerStart >= fence.count else { return false }
        return content[index...].allSatisfy { $0 == 0x20 || $0 == 0x09 }
    }

    private static func taskMarkerRange(
        in content: [UInt8],
        baseOffset: Int
    ) -> Range<Int>? {
        var index = 0
        while index < content.count, index < 4, content[index] == 0x20 {
            index += 1
        }
        guard index < content.count, index < 4 else { return nil }

        if content[index] == 0x2D || content[index] == 0x2A || content[index] == 0x2B {
            index += 1
        } else {
            let digitStart = index
            while index < content.count, content[index] >= 0x30, content[index] <= 0x39 {
                index += 1
            }
            guard
                index > digitStart,
                index < content.count,
                content[index] == 0x2E || content[index] == 0x29
            else { return nil }
            index += 1
        }
        guard index < content.count, content[index] == 0x20 || content[index] == 0x09 else {
            return nil
        }
        while index < content.count, content[index] == 0x20 || content[index] == 0x09 {
            index += 1
        }
        guard
            index + 2 < content.count,
            content[index] == 0x5B,
            content[index + 1] == 0x20
                || content[index + 1] == 0x78
                || content[index + 1] == 0x58,
            content[index + 2] == 0x5D
        else { return nil }
        let next = index + 3
        guard
            next == content.count
                || content[next] == 0x20
                || content[next] == 0x09
        else { return nil }
        return (baseOffset + index)..<(baseOffset + index + 3)
    }

    private static func headingTextRange(
        in content: [UInt8],
        baseOffset: Int
    ) -> (level: Int, textRange: Range<Int>)? {
        var index = 0
        while index < content.count, content[index] == 0x23, index < 6 {
            index += 1
        }
        guard
            index > 0,
            index < content.count,
            content[index] == 0x20 || content[index] == 0x09
        else { return nil }
        let level = index
        while index < content.count, content[index] == 0x20 || content[index] == 0x09 {
            index += 1
        }
        return (level, (baseOffset + index)..<(baseOffset + content.count))
    }

    private static func listItemTextRange(
        in content: [UInt8],
        baseOffset: Int
    ) -> Range<Int>? {
        var index = 0
        while index < content.count, index < 3, content[index] == 0x20 {
            index += 1
        }
        guard index < content.count else { return nil }
        if content[index] == 0x2D || content[index] == 0x2A || content[index] == 0x2B {
            index += 1
        } else {
            let digitStart = index
            while index < content.count, content[index] >= 0x30, content[index] <= 0x39 {
                index += 1
            }
            guard
                index > digitStart,
                index < content.count,
                content[index] == 0x2E || content[index] == 0x29
            else { return nil }
            index += 1
        }
        guard index < content.count, content[index] == 0x20 || content[index] == 0x09 else {
            return nil
        }
        while index < content.count, content[index] == 0x20 || content[index] == 0x09 {
            index += 1
        }
        return (baseOffset + index)..<(baseOffset + content.count)
    }

    private static func quoteTextRange(
        in content: [UInt8],
        baseOffset: Int
    ) -> Range<Int>? {
        var index = 0
        while index < content.count, index < 3, content[index] == 0x20 {
            index += 1
        }
        guard index < content.count, content[index] == 0x3E else { return nil }
        while index < content.count, content[index] == 0x3E {
            index += 1
            if index < content.count, content[index] == 0x20 || content[index] == 0x09 {
                index += 1
            }
        }
        return (baseOffset + index)..<(baseOffset + content.count)
    }

    /// Marker content only becomes a structured node when every byte is plain,
    /// known-safe text and the line cannot be re-interpreted as another block
    /// (nested list, thematic break, or a Setext underline on the next line).
    private static func isStructurableContent(
        _ content: [UInt8],
        next: [UInt8]?
    ) -> Bool {
        guard isSafePlainText(content) else { return false }
        if isListPrefix(content) { return false }
        if isThematicBreak(content) { return false }
        if let next, isSetextDelimiter(next) { return false }
        return true
    }

    private static func isPlainParagraph(_ content: [UInt8], next: [UInt8]?) -> Bool {
        guard !content.isEmpty, isSafePlainText(content) else { return false }
        if isIndentedCode(content) {
            return false
        }
        let trimmed = content.drop(while: { $0 == 0x20 || $0 == 0x09 })
        if trimmed.first == 0x3E { return false }
        if isListPrefix(Array(trimmed)) { return false }
        if isThematicBreak(Array(trimmed)) { return false }
        if let next, isSetextDelimiter(next) { return false }
        return true
    }

    /// Every forbidden token is pure ASCII, so scanning bytes is exactly
    /// equivalent to the substring check it replaces and keeps each line O(n).
    /// "<!--" needs no dedicated scan: any occurrence contains a bare "<".
    private static let forbiddenBytes: Set<UInt8> = [
        0x5B, 0x5D,  // [ ]
        0x60,  // `
        0x2A, 0x5F, 0x7E,  // * _ ~
        0x3C, 0x3E,  // < >
        0x23, 0x5C, 0x24, 0x7C, 0x5E, 0x7B, 0x7D,  // # \ $ | ^ { }
    ]

    private static func isSafePlainText(_ content: [UInt8]) -> Bool {
        if content.contains(where: forbiddenBytes.contains) { return false }
        return !contains(content, ascii: "-->")
            && !contains(content, ascii: "%%")
            && !contains(content, ascii: "==")
            && !contains(content, ascii: "::")
    }

    private static func isIndentedCode(_ content: [UInt8]) -> Bool {
        content.first == 0x09 || content.starts(with: [0x20, 0x20, 0x20, 0x20])
    }

    private static func isListPrefix(_ content: [UInt8]) -> Bool {
        guard !content.isEmpty else { return false }
        if content.count > 1,
            content[0] == 0x2D || content[0] == 0x2A || content[0] == 0x2B,
            content[1] == 0x20 || content[1] == 0x09
        {
            return true
        }
        var index = 0
        while index < content.count, content[index] >= 0x30, content[index] <= 0x39 {
            index += 1
        }
        return index > 0
            && index + 1 < content.count
            && (content[index] == 0x2E || content[index] == 0x29)
            && (content[index + 1] == 0x20 || content[index + 1] == 0x09)
    }

    private static func isSetextDelimiter(_ content: [UInt8]) -> Bool {
        let trimmed = content.filter { $0 != 0x20 && $0 != 0x09 }
        guard !trimmed.isEmpty, let first = trimmed.first, first == 0x3D || first == 0x2D else {
            return false
        }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func isThematicBreak(_ content: [UInt8]) -> Bool {
        let marker = content.filter { $0 != 0x20 && $0 != 0x09 }
        return marker.count >= 3 && marker.allSatisfy { $0 == 0x2D }
    }

    private static func isMathBlockDelimiter(_ content: [UInt8]) -> Bool {
        var start = 0
        var end = content.count
        while start < end, isASCIIWhitespace(content[start]) { start += 1 }
        while end > start, isASCIIWhitespace(content[end - 1]) { end -= 1 }
        return content[start..<end].elementsEqual("$$".utf8)
    }

    private static func openingHTMLBlockTag(_ content: [UInt8]) -> String? {
        let trimmed = Array(content.drop(while: isASCIIWhitespace))
        guard trimmed.count >= 3, trimmed[0] == 0x3C, isASCIILetter(trimmed[1]) else {
            return nil
        }
        var index = 2
        while index < trimmed.count,
            isASCIILetter(trimmed[index]) || isASCIIDigit(trimmed[index]) || trimmed[index] == 0x2D
        {
            index += 1
        }
        guard
            index < trimmed.count,
            isASCIIWhitespace(trimmed[index]) || trimmed[index] == 0x2F || trimmed[index] == 0x3E
        else { return nil }

        let tag = String(decoding: trimmed[1..<index], as: UTF8.self).lowercased()
        let text = String(decoding: trimmed, as: UTF8.self).lowercased()
        let voidTags: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
            "param", "source", "track", "wbr",
        ]
        guard
            !voidTags.contains(tag),
            !text.hasSuffix("/>")
        else { return nil }
        return tag
    }

    private static func htmlTagBalance(_ tag: String, in content: [UInt8]) -> Int {
        let bytes = content.map(asciiLowercased)
        let tagBytes = Array(tag.utf8)
        var balance = 0
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x3C else {
                index += 1
                continue
            }
            var nameStart = index + 1
            let isClosing = nameStart < bytes.count && bytes[nameStart] == 0x2F
            if isClosing { nameStart += 1 }
            let nameEnd = nameStart + tagBytes.count
            guard
                nameEnd <= bytes.count,
                bytes[nameStart..<nameEnd].elementsEqual(tagBytes),
                nameEnd < bytes.count,
                isASCIIWhitespace(bytes[nameEnd])
                    || bytes[nameEnd] == 0x2F
                    || bytes[nameEnd] == 0x3E,
                let tagEnd = bytes[nameEnd...].firstIndex(of: 0x3E)
            else {
                index += 1
                continue
            }
            var beforeEnd = tagEnd
            while beforeEnd > nameEnd, isASCIIWhitespace(bytes[beforeEnd - 1]) {
                beforeEnd -= 1
            }
            let isSelfClosing = beforeEnd > nameEnd && bytes[beforeEnd - 1] == 0x2F
            if isClosing {
                balance -= 1
            } else if !isSelfClosing {
                balance += 1
            }
            index = tagEnd + 1
        }
        return balance
    }

    private static func occurrences(of token: String, in content: [UInt8]) -> Int {
        let source = Array(content)
        let needle = Array(token.utf8)
        guard !needle.isEmpty, needle.count <= source.count else { return 0 }
        var result = 0
        var offset = 0
        while offset <= source.count - needle.count {
            if source[offset..<(offset + needle.count)].elementsEqual(needle) {
                result += 1
                offset += needle.count
            } else {
                offset += 1
            }
        }
        return result
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    private static func contains(_ content: [UInt8], ascii token: String) -> Bool {
        // Plain index arithmetic: building an ArraySlice per candidate position
        // dominates the profile for large documents in unoptimized builds.
        let needle = Array(token.utf8)
        guard !needle.isEmpty, needle.count <= content.count else { return false }
        var start = 0
        let lastStart = content.count - needle.count
        while start <= lastStart {
            var offset = 0
            while offset < needle.count, content[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return true }
            start += 1
        }
        return false
    }
}

extension MarkdownSourceMapParser {
    private static func validate(_ nodes: [MarkdownSourceNode], in data: Data) -> Bool {
        if data.isEmpty { return nodes.isEmpty }
        var expectedStart = 0
        for node in nodes {
            guard
                node.sourceRange.lowerBound == expectedStart,
                node.sourceRange.upperBound <= data.count,
                !node.sourceRange.isEmpty,
                String(data: data.subdata(in: node.sourceRange), encoding: .utf8) != nil
            else { return false }
            expectedStart = node.sourceRange.upperBound

            var previousSpanEnd = node.sourceRange.lowerBound
            for span in node.editableSpans {
                guard
                    span.range.lowerBound >= previousSpanEnd,
                    span.range.upperBound <= node.sourceRange.upperBound,
                    data.subdata(in: span.range) == span.expectedOriginal,
                    String(data: span.expectedOriginal, encoding: .utf8) != nil
                else { return false }
                previousSpanEnd = span.range.upperBound
            }
        }
        return expectedStart == data.count
    }

    private static func sourceInformation(for data: Data) -> MarkdownSourceInfo {
        let bytes = Array(data)
        var containsLF = false
        var containsCRLF = false
        for index in bytes.indices where bytes[index] == 0x0A {
            if index > 0, bytes[index - 1] == 0x0D {
                containsCRLF = true
            } else {
                containsLF = true
            }
        }
        let lineEnding: MarkdownLineEnding
        switch (containsLF, containsCRLF) {
        case (false, false): lineEnding = .none
        case (true, false): lineEnding = .lf
        case (false, true): lineEnding = .crlf
        case (true, true): lineEnding = .mixed
        }
        return MarkdownSourceInfo(
            hasUTF8BOM: bytes.starts(with: utf8BOM),
            lineEnding: lineEnding
        )
    }
}
