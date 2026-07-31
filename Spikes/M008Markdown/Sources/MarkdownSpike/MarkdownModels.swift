import Foundation

public enum MarkdownSpike {
    public enum Error: Swift.Error, Equatable {
        case invalidUTF8
    }

    public enum FrontmatterState: Equatable, Sendable {
        case absent
        case valid
        case invalid
    }

    public enum LineEnding: Equatable, Sendable {
        case none
        case lf
        case crlf
        case mixed
    }

    public enum ASTNodeKind: Equatable, Sendable {
        case heading
        case paragraph
        case emphasis
        case strong
        case strikethrough
        case link
        case image
        case inlineCode
        case codeBlock
        case blockQuote
        case orderedList
        case unorderedList
    }

    public struct Frontmatter: Equatable, Sendable {
        public let state: FrontmatterState
        public let title: String?
        public let tags: [String]
    }

    public struct Encoding: Equatable, Sendable {
        public let utf8BOM: Bool
        public let lineEnding: LineEnding
    }

    public struct AST: Equatable, Sendable {
        public let nodeKinds: [ASTNodeKind]
        public let standardLinks: [String]
        public let standardImages: [String]
    }

    public struct WikiLink: Equatable, Sendable {
        public let source: String
        public let target: String
        public let alias: String?
    }

    public struct Embed: Equatable, Sendable {
        public let source: String
        public let target: String
    }

    public struct Analysis: Equatable, Sendable {
        public let originalData: Data
        public let source: String
        public let body: String
        public let encoding: Encoding
        public let frontmatter: Frontmatter
        public let ast: AST
        public let inlineTags: [String]
        public let wikiLinks: [WikiLink]
        public let embeds: [Embed]
        /// Unsanitized dependency output for Spike inspection only.
        ///
        /// It must never be displayed in a web view or treated as trusted HTML.
        public let diagnosticHTML: String
        public let diagnostics: [String]
    }
}
