import Foundation
import Markdown

/// A standard Markdown tree and its byte range in the original note.
///
/// Locations inside `document` are relative to the parsed body, while
/// `bodyRange` maps that body back to the original data.
public struct MarkdownAST {
    public let bodyRange: Range<Int>
    public let document: Document
    let bodyData: Data
}

enum MarkdownASTParser {
    /// Parses exactly the body selected by `FrontmatterParser`.
    static func parse(_ frontmatter: FrontmatterParseResult) -> MarkdownAST {
        let bodyData = frontmatter.bodyData
        let body = String(decoding: bodyData, as: UTF8.self)
        return MarkdownAST(
            bodyRange: frontmatter.bodyRange,
            document: Document(parsing: body),
            bodyData: bodyData
        )
    }
}
