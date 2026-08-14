public struct MarkdownParseLimits: Equatable, Sendable {
    public static let `default` = MarkdownParseLimits()

    public let maximumNoteBytes: Int
    public let maximumFrontmatterBytes: Int
    public let maximumYAMLNodes: Int
    public let maximumYAMLDepth: Int
    public let maximumYAMLAliases: Int
    public let maximumFrontmatterTags: Int
    public let maximumSyntaxOccurrences: Int
    public let maximumSyntaxTokenBytes: Int
    public let maximumUniqueTags: Int
    public let maximumPreviewCharacters: Int

    public init(
        maximumNoteBytes: Int = 1_024 * 1_024,
        maximumFrontmatterBytes: Int = 64 * 1_024,
        maximumYAMLNodes: Int = 2_048,
        maximumYAMLDepth: Int = 32,
        maximumYAMLAliases: Int = 128,
        maximumFrontmatterTags: Int = 1_024,
        maximumSyntaxOccurrences: Int = 10_000,
        maximumSyntaxTokenBytes: Int = 4 * 1_024,
        maximumUniqueTags: Int = 1_024,
        maximumPreviewCharacters: Int = 200
    ) {
        self.maximumNoteBytes = maximumNoteBytes
        self.maximumFrontmatterBytes = maximumFrontmatterBytes
        self.maximumYAMLNodes = maximumYAMLNodes
        self.maximumYAMLDepth = maximumYAMLDepth
        self.maximumYAMLAliases = maximumYAMLAliases
        self.maximumFrontmatterTags = maximumFrontmatterTags
        self.maximumSyntaxOccurrences = maximumSyntaxOccurrences
        self.maximumSyntaxTokenBytes = maximumSyntaxTokenBytes
        self.maximumUniqueTags = maximumUniqueTags
        self.maximumPreviewCharacters = maximumPreviewCharacters
    }

    var isValid: Bool {
        maximumNoteBytes >= 0
            && maximumFrontmatterBytes >= 0
            && maximumYAMLNodes >= 0
            && maximumYAMLDepth >= 0
            && maximumYAMLAliases >= 0
            && maximumFrontmatterTags >= 0
            && maximumSyntaxOccurrences >= 0
            && maximumSyntaxTokenBytes >= 0
            && maximumUniqueTags >= 0
            && maximumPreviewCharacters >= 0
    }
}

public enum MarkdownParseError: Error, Equatable, Sendable {
    case invalidLimits
    case noteTooLarge(actual: Int, limit: Int)
    case invalidUTF8
}

public enum MarkdownDiagnostic: String, Equatable, Sendable {
    case invalidFrontmatter = "frontmatter.invalid-yaml"
    case unclosedFrontmatter = "frontmatter.unclosed"
    case frontmatterResourceLimit = "frontmatter.resource-limit"
    case syntaxSourceRangeInvalid = "syntax.source-range-invalid"
    case syntaxOccurrenceLimit = "syntax.occurrence-limit"
    case syntaxTokenLimit = "syntax.token-limit"
    case uniqueTagLimit = "metadata.unique-tag-limit"
}

public enum MarkdownParseStatus: Equatable, Sendable {
    case complete
    case degraded
}

public enum MarkdownLineEnding: Equatable, Sendable {
    case none
    case lf
    case crlf
    case mixed
}

public struct MarkdownSourceInfo: Equatable, Sendable {
    public let hasUTF8BOM: Bool
    public let lineEnding: MarkdownLineEnding

    public init(hasUTF8BOM: Bool, lineEnding: MarkdownLineEnding) {
        self.hasUTF8BOM = hasUTF8BOM
        self.lineEnding = lineEnding
    }
}

public struct ParsedTag: Equatable, Sendable {
    public let normalizedName: String
    public let displayName: String

    public init(normalizedName: String, displayName: String) {
        self.normalizedName = normalizedName
        self.displayName = displayName
    }
}

public struct ParsedNote {
    public let title: String
    public let preview: String
    public let tags: [ParsedTag]
    public let frontmatter: FrontmatterParseResult
    public let ast: MarkdownAST
    public let syntax: ObsidianSyntaxScanResult
    public let sourceInfo: MarkdownSourceInfo
    public let diagnostics: [MarkdownDiagnostic]

    public var status: MarkdownParseStatus {
        diagnostics.isEmpty ? .complete : .degraded
    }
}
