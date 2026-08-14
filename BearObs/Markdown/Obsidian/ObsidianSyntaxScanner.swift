import Foundation
import Markdown

enum ObsidianSyntaxScanner {
    /// Scans only the body represented by `markdown`.
    ///
    /// Every source range is a half-open UTF-8 byte range in the original note.
    static func scan(
        _ markdown: MarkdownAST,
        maximumOccurrences: Int = .max,
        maximumTokenBytes: Int = .max
    ) -> ObsidianSyntaxScanResult {
        precondition(maximumOccurrences >= 0 && maximumTokenBytes >= 0)
        let body = BodySource(markdown.bodyData)
        var walker = ExclusionWalker(source: body)
        walker.visit(markdown.document)
        guard !walker.hasInvalidRange else {
            return ObsidianSyntaxScanResult(
                inlineTags: [],
                wikiLinks: [],
                embeds: [],
                diagnostic: .sourceRangeInvalid
            )
        }

        let visible = body.masking(
            walker.excludedRanges,
            restoring: walker.restoredRanges
        )
        return TokenScanner(
            visible: visible,
            original: body.bytes,
            baseOffset: markdown.bodyRange.lowerBound,
            maximumOccurrences: maximumOccurrences,
            maximumTokenBytes: maximumTokenBytes
        ).scan()
    }
}

private struct BodySource {
    let bytes: [UInt8]
    private let lineStarts: [Int]

    init(_ data: Data) {
        let bytes = Array(data)
        self.bytes = bytes
        lineStarts = bytes.indices.reduce(into: [0]) { starts, index in
            if bytes[index] == 0x0A {
                starts.append(index + 1)
            }
        }
    }

    func byteRange(_ sourceRange: SourceRange?) -> Range<Int>? {
        guard
            let sourceRange,
            let lowerBound = byteOffset(sourceRange.lowerBound),
            let upperBound = byteOffset(sourceRange.upperBound),
            lowerBound <= upperBound,
            upperBound <= bytes.count
        else {
            return nil
        }
        return lowerBound..<upperBound
    }

    func masking(_ ranges: [Range<Int>], restoring restored: [Range<Int>]) -> [UInt8] {
        var visible = bytes
        for range in ranges {
            for index in range where visible[index] != 0x0A && visible[index] != 0x0D {
                visible[index] = 0x20
            }
        }
        for range in restored {
            visible.replaceSubrange(range, with: bytes[range])
        }
        return visible
    }

    private func byteOffset(_ location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineStarts.indices.contains(lineIndex), location.column > 0 else {
            return nil
        }
        return lineStarts[lineIndex] + location.column - 1
    }
}

private struct ExclusionWalker: MarkupWalker {
    let source: BodySource
    private(set) var excludedRanges: [Range<Int>] = []
    private(set) var restoredRanges: [Range<Int>] = []
    private(set) var hasInvalidRange = false

    mutating func visitLink(_ link: Link) {
        exclude(link.range)
        if !isAngleAutolink(link) {
            restoreTextRanges(in: link)
        }
    }

    mutating func visitImage(_ image: Image) {
        exclude(image.range)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        exclude(inlineCode.range)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        exclude(codeBlock.range)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        exclude(inlineHTML.range)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        exclude(html.range)
    }

    private mutating func exclude(_ range: SourceRange?) {
        guard let range = source.byteRange(range) else {
            hasInvalidRange = true
            return
        }
        excludedRanges.append(range)
    }

    private mutating func restoreTextRanges(in markup: Markup) {
        if markup is Image || markup is InlineCode || markup is InlineHTML {
            return
        }
        if let text = markup as? Text {
            guard let range = source.byteRange(text.range) else {
                hasInvalidRange = true
                return
            }
            restoredRanges.append(range)
        }
        for child in markup.children {
            restoreTextRanges(in: child)
        }
    }

    private func isAngleAutolink(_ link: Link) -> Bool {
        guard
            let range = source.byteRange(link.range),
            range.count >= 2,
            source.bytes[range.lowerBound] == 0x3C,
            source.bytes[range.upperBound - 1] == 0x3E
        else {
            return false
        }
        return true
    }
}

private struct TokenScanner {
    private let characters: [Character]
    private let byteOffsets: [Int]
    private let nextBracketClose: [Int?]
    private let original: [UInt8]
    private let baseOffset: Int
    private let maximumOccurrences: Int
    private let maximumTokenBytes: Int

    init(
        visible: [UInt8],
        original: [UInt8],
        baseOffset: Int,
        maximumOccurrences: Int,
        maximumTokenBytes: Int
    ) {
        let characters = Array(String(decoding: visible, as: UTF8.self))
        self.characters = characters
        nextBracketClose = Self.makeNextBracketClose(for: characters)
        self.original = original
        self.baseOffset = baseOffset
        self.maximumOccurrences = maximumOccurrences
        self.maximumTokenBytes = maximumTokenBytes

        var offsets = [0]
        offsets.reserveCapacity(characters.count + 1)
        for character in characters {
            offsets.append(offsets[offsets.count - 1] + String(character).utf8.count)
        }
        byteOffsets = offsets
    }

    func scan() -> ObsidianSyntaxScanResult {
        var inlineTags: [InlineTag] = []
        var wikiLinks: [WikiLink] = []
        var embeds: [ObsidianEmbed] = []
        var index = 0

        while index < characters.count {
            if isEmbedStart(at: index), let token = bracketToken(at: index + 1) {
                let bounds = index..<token.endIndex
                guard !token.exceedsLimit, withinTokenLimit(bounds) else {
                    return tokenLimitedResult(inlineTags, wikiLinks, embeds)
                }
                if !isEscaped(at: index), let target = token.target {
                    guard canAppend(inlineTags, wikiLinks, embeds) else {
                        return limitedResult(inlineTags, wikiLinks, embeds)
                    }
                    embeds.append(
                        ObsidianEmbed(
                            source: originalSource(in: bounds),
                            target: target,
                            sourceRange: absoluteRange(for: bounds)
                        )
                    )
                }
                index = token.endIndex
                continue
            }
            if isWikiLinkStart(at: index), let token = bracketToken(at: index) {
                let bounds = index..<token.endIndex
                guard !token.exceedsLimit, withinTokenLimit(bounds) else {
                    return tokenLimitedResult(inlineTags, wikiLinks, embeds)
                }
                if !isEscaped(at: index), let target = token.target {
                    guard canAppend(inlineTags, wikiLinks, embeds) else {
                        return limitedResult(inlineTags, wikiLinks, embeds)
                    }
                    wikiLinks.append(
                        WikiLink(
                            source: originalSource(in: bounds),
                            target: target,
                            alias: token.alias,
                            sourceRange: absoluteRange(for: bounds)
                        )
                    )
                }
                index = token.endIndex
                continue
            }
            if characters[index] == "#", !isEscaped(at: index), isTagBoundary(at: index) {
                let end = tagEnd(after: index)
                if end > index + 1 {
                    let bounds = index..<end
                    guard withinTokenLimit(bounds) else {
                        return tokenLimitedResult(inlineTags, wikiLinks, embeds)
                    }
                    guard canAppend(inlineTags, wikiLinks, embeds) else {
                        return limitedResult(inlineTags, wikiLinks, embeds)
                    }
                    let source = originalSource(in: bounds)
                    inlineTags.append(
                        InlineTag(
                            source: source,
                            name: String(source.dropFirst()),
                            sourceRange: absoluteRange(for: bounds)
                        )
                    )
                    index = end
                    continue
                }
            }
            index += 1
        }

        return ObsidianSyntaxScanResult(
            inlineTags: inlineTags,
            wikiLinks: wikiLinks,
            embeds: embeds
        )
    }

    private func canAppend(
        _ inlineTags: [InlineTag],
        _ wikiLinks: [WikiLink],
        _ embeds: [ObsidianEmbed]
    ) -> Bool {
        inlineTags.count + wikiLinks.count + embeds.count < maximumOccurrences
    }

    private func limitedResult(
        _ inlineTags: [InlineTag],
        _ wikiLinks: [WikiLink],
        _ embeds: [ObsidianEmbed]
    ) -> ObsidianSyntaxScanResult {
        ObsidianSyntaxScanResult(
            inlineTags: inlineTags,
            wikiLinks: wikiLinks,
            embeds: embeds,
            diagnostic: .occurrenceLimit
        )
    }

    private func tokenLimitedResult(
        _ inlineTags: [InlineTag],
        _ wikiLinks: [WikiLink],
        _ embeds: [ObsidianEmbed]
    ) -> ObsidianSyntaxScanResult {
        ObsidianSyntaxScanResult(
            inlineTags: inlineTags,
            wikiLinks: wikiLinks,
            embeds: embeds,
            diagnostic: .tokenLimit
        )
    }

    private func withinTokenLimit(_ range: Range<Int>) -> Bool {
        relativeByteRange(for: range).count <= maximumTokenBytes
    }

    private struct BracketToken {
        let target: String?
        let alias: String?
        let endIndex: Int
        let exceedsLimit: Bool
    }

    private func bracketToken(at start: Int) -> BracketToken? {
        let contentStart = start + 2
        guard
            isWikiLinkStart(at: start),
            nextBracketClose.indices.contains(contentStart),
            let end = nextBracketClose[contentStart]
        else {
            return nil
        }
        let endIndex = end + 2
        guard withinTokenLimit(start..<endIndex) else {
            return BracketToken(
                target: nil,
                alias: nil,
                endIndex: endIndex,
                exceedsLimit: true
            )
        }
        let content = String(characters[contentStart..<end])
        let parts = content.split(
            separator: "|",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        return BracketToken(
            target: nonempty(String(parts[0])),
            alias: parts.count == 2 ? nonempty(String(parts[1])) : nil,
            endIndex: endIndex,
            exceedsLimit: false
        )
    }

    private func isEmbedStart(at index: Int) -> Bool {
        index + 2 < characters.count
            && characters[index] == "!"
            && isWikiLinkStart(at: index + 1)
    }

    private func isWikiLinkStart(at index: Int) -> Bool {
        index + 1 < characters.count
            && characters[index] == "["
            && characters[index + 1] == "["
    }

    private func nonempty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isEscaped(at index: Int) -> Bool {
        !backslashStart(before: index).distance(to: index).isMultiple(of: 2)
    }

    private func isTagBoundary(at index: Int) -> Bool {
        let boundary = backslashStart(before: index)
        guard boundary > 0 else {
            return true
        }
        let previous = characters[boundary - 1]
        return previous == "﻿"
            || previous.isWhitespace
            || "([{:;,.“”‘’".contains(previous)
    }

    private func backslashStart(before index: Int) -> Int {
        var cursor = index
        while cursor > 0, characters[cursor - 1] == "\\" {
            cursor -= 1
        }
        return cursor
    }

    private func tagEnd(after marker: Int) -> Int {
        var index = marker + 1
        guard index < characters.count, characters[index].isTagInitial else {
            return index
        }
        index += 1
        while index < characters.count, characters[index].isTagContinuation {
            index += 1
        }
        return index
    }

    private func originalSource(in characterRange: Range<Int>) -> String {
        let range = relativeByteRange(for: characterRange)
        return String(decoding: original[range], as: UTF8.self)
    }

    private func absoluteRange(for characterRange: Range<Int>) -> Range<Int> {
        let range = relativeByteRange(for: characterRange)
        return (range.lowerBound + baseOffset)..<(range.upperBound + baseOffset)
    }

    private func relativeByteRange(for characterRange: Range<Int>) -> Range<Int> {
        byteOffsets[characterRange.lowerBound]..<byteOffsets[characterRange.upperBound]
    }

    private static func makeNextBracketClose(for characters: [Character]) -> [Int?] {
        var result = [Int?](repeating: nil, count: characters.count + 1)
        guard characters.count >= 2 else {
            return result
        }

        var next: Int?
        for index in stride(from: characters.count - 2, through: 0, by: -1) {
            if characters[index] == "\n" || characters[index] == "\r" {
                next = nil
            } else if characters[index] == "]", characters[index + 1] == "]" {
                next = index
            }
            result[index] = next
        }
        return result
    }
}

extension Character {
    fileprivate var isTagInitial: Bool {
        unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_"
        }
    }

    fileprivate var isTagContinuation: Bool {
        isTagInitial || self == "-" || self == "/"
    }
}
