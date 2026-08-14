import Foundation
import Markdown

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public enum MarkdownNoteParser {
    public static func parse(
        _ data: Data,
        at path: VaultPath,
        limits: MarkdownParseLimits = .default
    ) throws -> ParsedNote {
        guard limits.isValid else {
            throw MarkdownParseError.invalidLimits
        }
        guard data.count <= limits.maximumNoteBytes else {
            throw MarkdownParseError.noteTooLarge(
                actual: data.count,
                limit: limits.maximumNoteBytes
            )
        }

        let frontmatter: FrontmatterParseResult
        do {
            frontmatter = try FrontmatterParser.parse(
                data,
                limits: FrontmatterResourceLimits(
                    maximumBytes: limits.maximumFrontmatterBytes,
                    maximumNodes: limits.maximumYAMLNodes,
                    maximumDepth: limits.maximumYAMLDepth,
                    maximumAliases: limits.maximumYAMLAliases,
                    maximumTags: limits.maximumFrontmatterTags
                )
            )
        } catch FrontmatterParseError.invalidUTF8 {
            throw MarkdownParseError.invalidUTF8
        }

        let ast = MarkdownASTParser.parse(frontmatter)
        let syntax = ObsidianSyntaxScanner.scan(
            ast,
            maximumOccurrences: limits.maximumSyntaxOccurrences,
            maximumTokenBytes: limits.maximumSyntaxTokenBytes
        )
        let aggregation = aggregateTags(
            frontmatter.tags,
            syntax.inlineTags,
            maximumCount: limits.maximumUniqueTags
        )
        var diagnostics = diagnostics(for: frontmatter, syntax: syntax)
        if aggregation.truncated {
            diagnostics.append(.uniqueTagLimit)
        }

        let body = BodySource(ast.bodyData)
        let children = Array(ast.document.children)
        let headingIndex = children.firstIndex {
            guard let heading = $0 as? Heading else { return false }
            return heading.level == 1 && body.isATXHeading(heading)
        }
        let textSource = VisibleTextSource(body: body, syntax: syntax, bodyRange: ast.bodyRange)
        let frontmatterTitle = frontmatter.title.map(collapseWhitespace).flatMap {
            $0.isEmpty ? nil : $0
        }
        let headingTitle = headingIndex.map {
            textSource.text(in: children[$0], maximumCount: .max)
        }.flatMap { $0.isEmpty ? nil : $0 }
        let adoptedHeadingIndex =
            frontmatterTitle == nil && headingTitle != nil ? headingIndex : nil

        return ParsedNote(
            title: title(
                frontmatterTitle: frontmatterTitle,
                headingTitle: headingTitle,
                path: path
            ),
            preview: preview(
                children: children,
                startAfterHeading: adoptedHeadingIndex,
                textSource: textSource,
                maximumCount: limits.maximumPreviewCharacters
            ),
            tags: aggregation.tags,
            frontmatter: frontmatter,
            ast: ast,
            syntax: syntax,
            sourceInfo: sourceInfo(data),
            diagnostics: diagnostics
        )
    }
}

extension MarkdownNoteParser {
    private struct TagAggregation {
        let tags: [ParsedTag]
        let truncated: Bool
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let normalizationLocale = Locale(identifier: "en_US_POSIX")

    private static func diagnostics(
        for frontmatter: FrontmatterParseResult,
        syntax: ObsidianSyntaxScanResult
    ) -> [MarkdownDiagnostic] {
        var result: [MarkdownDiagnostic] = []
        switch frontmatter.diagnostic {
        case .invalidYAML:
            result.append(.invalidFrontmatter)
        case .unclosed:
            result.append(.unclosedFrontmatter)
        case .resourceLimit:
            result.append(.frontmatterResourceLimit)
        case nil:
            break
        }
        switch syntax.diagnostic {
        case .sourceRangeInvalid:
            result.append(.syntaxSourceRangeInvalid)
        case .occurrenceLimit:
            result.append(.syntaxOccurrenceLimit)
        case .tokenLimit:
            result.append(.syntaxTokenLimit)
        case nil:
            break
        }
        return result
    }

    private static func title(
        frontmatterTitle: String?,
        headingTitle: String?,
        path: VaultPath
    ) -> String {
        if let title = frontmatterTitle {
            return title
        }
        if let headingTitle {
            return headingTitle
        }
        return path.fileNameWithoutExtension
    }

    private static func preview(
        children: [Markup],
        startAfterHeading headingIndex: Int?,
        textSource: VisibleTextSource,
        maximumCount: Int
    ) -> String {
        let start = headingIndex.map { $0 + 1 } ?? children.startIndex

        for child in children[start...] {
            guard let paragraph = child as? Paragraph else {
                continue
            }
            let text = textSource.text(in: paragraph, maximumCount: maximumCount)
            if !text.isEmpty {
                return text
            }
        }
        return ""
    }

    private static func aggregateTags(
        _ frontmatterTags: [String],
        _ inlineTags: [InlineTag],
        maximumCount: Int
    ) -> TagAggregation {
        let candidates = frontmatterTags + inlineTags.map(\.name)
        var seen: Set<String> = []
        var tags: [ParsedTag] = []
        for candidate in candidates {
            let display = displayTag(candidate)
            guard !display.isEmpty else { continue }
            let normalized = normalizedTag(display)
            guard seen.insert(normalized).inserted else { continue }
            guard tags.count < maximumCount else {
                return TagAggregation(tags: tags, truncated: true)
            }
            tags.append(ParsedTag(normalizedName: normalized, displayName: display))
        }
        return TagAggregation(tags: tags, truncated: false)
    }

    private static func displayTag(_ source: String) -> String {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "#" {
            value.removeFirst()
        }
        return value.precomposedStringWithCanonicalMapping
    }

    private static func normalizedTag(_ display: String) -> String {
        display
            .folding(options: [.caseInsensitive], locale: normalizationLocale)
            .precomposedStringWithCanonicalMapping
    }

    private static func collapseWhitespace(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func sourceInfo(_ data: Data) -> MarkdownSourceInfo {
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

private struct BodySource {
    let bytes: [UInt8]
    private let lineStarts: [Int]

    init(_ data: Data) {
        let bodyBytes = Array(data)
        bytes = bodyBytes
        lineStarts = bodyBytes.indices.reduce(into: [0]) { starts, index in
            if bodyBytes[index] == 0x0A {
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
            upper <= bytes.count
        else {
            return nil
        }
        return lower..<upper
    }

    func isATXHeading(_ heading: Heading) -> Bool {
        guard
            let line = heading.range?.lowerBound.line,
            line > 0,
            lineStarts.indices.contains(line - 1)
        else {
            return false
        }
        var index = lineStarts[line - 1]
        if index == 0, bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            index += 3
        }
        var spaces = 0
        while index < bytes.count, bytes[index] == 0x20, spaces < 3 {
            spaces += 1
            index += 1
        }
        guard index < bytes.count, bytes[index] == 0x23 else {
            return false
        }
        let next = index + 1
        return next == bytes.count || bytes[next] == 0x20 || bytes[next] == 0x09
    }

    private func byteOffset(_ location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineStarts.indices.contains(lineIndex), location.column > 0 else {
            return nil
        }
        return lineStarts[lineIndex] + location.column - 1
    }
}

private struct VisibleTextSource {
    private struct Token {
        let range: Range<Int>
        let source: String
        let replacement: String
    }

    private let body: BodySource
    private let tokens: [Token]

    init(
        body: BodySource,
        syntax: ObsidianSyntaxScanResult,
        bodyRange: Range<Int>
    ) {
        self.body = body
        let wiki = syntax.wikiLinks.map {
            Token(
                range: Self.relative($0.sourceRange, to: bodyRange),
                source: $0.source,
                replacement: $0.alias ?? $0.target
            )
        }
        let embeds = syntax.embeds.map {
            Token(
                range: Self.relative($0.sourceRange, to: bodyRange),
                source: $0.source,
                replacement: ""
            )
        }
        tokens = (wiki + embeds).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    func text(in markup: Markup, maximumCount: Int) -> String {
        var output = CollapsedText(maximumCount: maximumCount)
        append(markup, to: &output)
        return output.value
    }

    private func append(_ markup: Markup, to output: inout CollapsedText) {
        guard !output.isFull else { return }
        switch markup {
        case is Image, is InlineHTML:
            return
        case let code as InlineCode:
            output.append(code.code)
        case let text as Text:
            append(text, to: &output)
        case is SoftBreak, is LineBreak:
            output.append(" ")
        default:
            for child in markup.children {
                append(child, to: &output)
                if output.isFull { return }
            }
        }
    }

    private func append(_ text: Text, to output: inout CollapsedText) {
        guard
            let textRange = body.byteRange(text.range),
            !tokens.isEmpty
        else {
            output.append(text.string)
            return
        }
        let contained = tokens(in: textRange)
        guard !contained.isEmpty else {
            output.append(text.string)
            return
        }

        let raw = String(decoding: body.bytes[textRange], as: UTF8.self)
        let rendered = text.string
        var rawCursor = raw.startIndex
        var renderedCursor = rendered.startIndex

        for token in contained {
            guard !output.isFull else { return }
            let byteOffset = token.range.lowerBound - textRange.lowerBound
            guard
                let tokenStart = stringIndex(in: raw, utf8Offset: byteOffset),
                let occurrence = occurrenceNumber(
                    of: token.source,
                    in: raw,
                    from: rawCursor,
                    through: tokenStart
                ),
                let renderedRange = nthRange(
                    of: token.source,
                    occurrence: occurrence,
                    in: rendered,
                    from: renderedCursor
                )
            else {
                output.append(rendered[renderedCursor...])
                return
            }
            output.append(rendered[renderedCursor..<renderedRange.lowerBound])
            output.append(token.replacement)
            rawCursor = raw.index(tokenStart, offsetBy: token.source.count)
            renderedCursor = renderedRange.upperBound
        }
        output.append(rendered[renderedCursor...])
    }

    private func occurrenceNumber(
        of needle: String,
        in haystack: String,
        from start: String.Index,
        through target: String.Index
    ) -> Int? {
        var cursor = start
        var count = 0
        while let match = haystack.range(of: needle, range: cursor..<haystack.endIndex) {
            count += 1
            if match.lowerBound == target {
                return count
            }
            guard match.lowerBound < target else { return nil }
            cursor = match.upperBound
        }
        return nil
    }

    private func nthRange(
        of needle: String,
        occurrence: Int,
        in haystack: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var cursor = start
        for index in 1...occurrence {
            guard let match = haystack.range(of: needle, range: cursor..<haystack.endIndex) else {
                return nil
            }
            if index == occurrence { return match }
            cursor = match.upperBound
        }
        return nil
    }

    private func stringIndex(in string: String, utf8Offset: Int) -> String.Index? {
        guard
            let utf8Index = string.utf8.index(
                string.utf8.startIndex,
                offsetBy: utf8Offset,
                limitedBy: string.utf8.endIndex
            )
        else {
            return nil
        }
        return String.Index(utf8Index, within: string)
    }

    private func tokens(in range: Range<Int>) -> ArraySlice<Token> {
        var lower = tokens.startIndex
        var upper = tokens.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokens[middle].range.lowerBound < range.lowerBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var end = lower
        while end < tokens.endIndex,
            tokens[end].range.lowerBound < range.upperBound,
            tokens[end].range.upperBound <= range.upperBound
        {
            end += 1
        }
        return tokens[lower..<end]
    }

    private static func relative(_ range: Range<Int>, to bodyRange: Range<Int>) -> Range<Int> {
        (range.lowerBound - bodyRange.lowerBound)..<(range.upperBound - bodyRange.lowerBound)
    }
}

private struct CollapsedText {
    private(set) var value = ""
    private var count = 0
    private var pendingSpace = false
    private let maximumCount: Int

    init(maximumCount: Int) {
        self.maximumCount = maximumCount
    }

    var isFull: Bool {
        count >= maximumCount
    }

    mutating func append<S: StringProtocol>(_ source: S) {
        for character in source {
            if character.isWhitespace {
                pendingSpace = !value.isEmpty
                continue
            }
            if pendingSpace {
                guard appendCharacter(" ") else { return }
                pendingSpace = false
            }
            guard appendCharacter(character) else { return }
        }
    }

    private mutating func appendCharacter(_ character: Character) -> Bool {
        guard count < maximumCount else { return false }
        value.append(character)
        count += 1
        return true
    }
}
