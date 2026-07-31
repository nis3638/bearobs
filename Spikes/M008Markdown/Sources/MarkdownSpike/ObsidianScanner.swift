import Foundation
import Markdown

struct ObsidianScanner {
    struct Result {
        let tags: [String]
        let wikiLinks: [MarkdownSpike.WikiLink]
        let embeds: [MarkdownSpike.Embed]
    }

    static func scan(
        _ source: String,
        excluding ranges: [SourceRange],
        restoring restoredRanges: [SourceRange]
    ) -> Result {
        let visibleSource = masking(
            source,
            ranges: ranges,
            restoring: restoredRanges
        )
        let characters = Array(visibleSource)
        var tags: [String] = []
        var seenTags: Set<String> = []
        var wikiLinks: [MarkdownSpike.WikiLink] = []
        var embeds: [MarkdownSpike.Embed] = []
        var index = 0

        while index < characters.count {
            if characters[index] == "<",
                let end = characters[(index + 1)...].firstIndex(of: ">")
            {
                index = end + 1
                continue
            }
            if isEmbedStart(characters, at: index),
                let token = bracketToken(characters, at: index + 1)
            {
                if !isEscaped(characters, at: index), let target = token.target {
                    embeds.append(
                        .init(source: "!\(token.source)", target: target)
                    )
                }
                index = token.endIndex
                continue
            }
            if isWikiLinkStart(characters, at: index),
                let token = bracketToken(characters, at: index)
            {
                if !isEscaped(characters, at: index), let target = token.target {
                    wikiLinks.append(
                        .init(
                            source: token.source,
                            target: target,
                            alias: token.alias
                        )
                    )
                }
                index = token.endIndex
                continue
            }
            if characters[index] == "#",
                isTagBoundary(characters, before: index)
            {
                let end = tagEnd(in: characters, after: index)
                if end > index + 1 {
                    let tag = String(characters[(index + 1)..<end])
                    if seenTags.insert(tag).inserted {
                        tags.append(tag)
                    }
                    index = end
                    continue
                }
            }
            index += 1
        }

        return Result(tags: tags, wikiLinks: wikiLinks, embeds: embeds)
    }

    private struct BracketToken {
        let source: String
        let target: String?
        let alias: String?
        let endIndex: Int
    }

    private static func bracketToken(
        _ characters: [Character],
        at start: Int
    ) -> BracketToken? {
        guard isWikiLinkStart(characters, at: start) else {
            return nil
        }
        var end = start + 2
        while end + 1 < characters.count {
            if characters[end] == "]", characters[end + 1] == "]" {
                let content = String(characters[(start + 2)..<end])
                let parts = content.split(
                    separator: "|",
                    maxSplits: 1,
                    omittingEmptySubsequences: false
                )
                let target = nonempty(String(parts[0]))
                let alias = parts.count == 2 ? nonempty(String(parts[1])) : nil
                return BracketToken(
                    source: String(characters[start..<(end + 2)]),
                    target: target,
                    alias: alias,
                    endIndex: end + 2
                )
            }
            end += 1
        }
        return nil
    }

    private static func isEmbedStart(
        _ characters: [Character],
        at index: Int
    ) -> Bool {
        index + 2 < characters.count
            && characters[index] == "!"
            && isWikiLinkStart(characters, at: index + 1)
    }

    private static func isWikiLinkStart(
        _ characters: [Character],
        at index: Int
    ) -> Bool {
        index + 1 < characters.count
            && characters[index] == "["
            && characters[index + 1] == "["
    }

    private static func nonempty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isEscaped(
        _ characters: [Character],
        at index: Int
    ) -> Bool {
        var cursor = index
        var backslashCount = 0
        while cursor > 0, characters[cursor - 1] == "\\" {
            cursor -= 1
            backslashCount += 1
        }
        return !backslashCount.isMultiple(of: 2)
    }

    private static func isTagBoundary(
        _ characters: [Character],
        before index: Int
    ) -> Bool {
        guard index > 0 else {
            return true
        }
        let previous = characters[index - 1]
        return previous.isWhitespace
            || "([{:;,.".contains(previous)
    }

    private static func tagEnd(
        in characters: [Character],
        after markerIndex: Int
    ) -> Int {
        var index = markerIndex + 1
        guard index < characters.count, characters[index].isTagInitial else {
            return index
        }
        index += 1
        while index < characters.count, characters[index].isTagContinuation {
            index += 1
        }
        return index
    }

    private static func masking(
        _ source: String,
        ranges: [SourceRange],
        restoring restoredRanges: [SourceRange]
    ) -> String {
        let originalBytes = Array(source.utf8)
        var bytes = originalBytes
        let lineStarts = bytes.indices.reduce(into: [0]) { starts, index in
            if bytes[index] == 0x0A {
                starts.append(index + 1)
            }
        }

        for range in ranges {
            guard
                let bounds = byteRange(
                    range,
                    lineStarts: lineStarts,
                    byteCount: bytes.count
                )
            else {
                continue
            }
            for index in bounds
            where bytes[index] != 0x0A && bytes[index] != 0x0D {
                bytes[index] = 0x20
            }
        }
        for range in restoredRanges {
            guard
                let bounds = byteRange(
                    range,
                    lineStarts: lineStarts,
                    byteCount: bytes.count
                )
            else {
                continue
            }
            bytes.replaceSubrange(bounds, with: originalBytes[bounds])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func byteRange(
        _ range: SourceRange,
        lineStarts: [Int],
        byteCount: Int
    ) -> Range<Int>? {
        guard
            let start = byteOffset(range.lowerBound, lineStarts: lineStarts),
            let end = byteOffset(range.upperBound, lineStarts: lineStarts)
        else {
            return nil
        }
        let lowerBound = min(max(start, 0), byteCount)
        let upperBound = min(max(end, lowerBound), byteCount)
        return lowerBound..<upperBound
    }

    private static func byteOffset(
        _ location: SourceLocation,
        lineStarts: [Int]
    ) -> Int? {
        let lineIndex = location.line - 1
        guard lineStarts.indices.contains(lineIndex), location.column > 0 else {
            return nil
        }
        return lineStarts[lineIndex] + location.column - 1
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
