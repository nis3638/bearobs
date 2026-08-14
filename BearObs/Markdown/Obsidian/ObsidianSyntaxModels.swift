public struct InlineTag: Equatable, Sendable {
    public let source: String
    public let name: String
    public let sourceRange: Range<Int>

    public init(source: String, name: String, sourceRange: Range<Int>) {
        self.source = source
        self.name = name
        self.sourceRange = sourceRange
    }
}

public struct WikiLink: Equatable, Sendable {
    public let source: String
    public let target: String
    public let alias: String?
    public let sourceRange: Range<Int>

    public init(source: String, target: String, alias: String?, sourceRange: Range<Int>) {
        self.source = source
        self.target = target
        self.alias = alias
        self.sourceRange = sourceRange
    }
}

public struct ObsidianEmbed: Equatable, Sendable {
    public let source: String
    public let target: String
    public let sourceRange: Range<Int>

    public init(source: String, target: String, sourceRange: Range<Int>) {
        self.source = source
        self.target = target
        self.sourceRange = sourceRange
    }
}

public struct ObsidianSyntaxScanResult: Equatable, Sendable {
    public let inlineTags: [InlineTag]
    public let wikiLinks: [WikiLink]
    public let embeds: [ObsidianEmbed]
    public let diagnostic: ObsidianSyntaxDiagnostic?

    public init(
        inlineTags: [InlineTag],
        wikiLinks: [WikiLink],
        embeds: [ObsidianEmbed],
        diagnostic: ObsidianSyntaxDiagnostic? = nil
    ) {
        self.inlineTags = inlineTags
        self.wikiLinks = wikiLinks
        self.embeds = embeds
        self.diagnostic = diagnostic
    }
}

public enum ObsidianSyntaxDiagnostic: String, Equatable, Sendable {
    case sourceRangeInvalid = "syntax.source-range-invalid"
    case occurrenceLimit = "syntax.occurrence-limit"
    case tokenLimit = "syntax.token-limit"
}
