import Foundation
import Markdown

extension MarkdownSpike {
    public static func analyze(_ data: Data) throws -> Analysis {
        guard let decodedSource = String(data: data, encoding: .utf8) else {
            throw Error.invalidUTF8
        }

        let encoding = Encoding(
            utf8BOM: data.starts(with: [0xEF, 0xBB, 0xBF]),
            lineEnding: detectLineEnding(in: decodedSource)
        )
        let source = decodedSource.removingLeadingBOM
        let frontmatterResult = FrontmatterProbe.parse(source)
        let document = Document(parsing: frontmatterResult.body)
        var astProbe = ASTProbe()
        astProbe.visit(document)
        let scanned = ObsidianScanner.scan(
            frontmatterResult.body,
            excluding: astProbe.excludedRanges,
            restoring: astProbe.restoredRanges
        )

        return Analysis(
            originalData: data,
            source: source,
            body: frontmatterResult.body,
            encoding: encoding,
            frontmatter: frontmatterResult.frontmatter,
            ast: astProbe.result,
            inlineTags: scanned.tags,
            wikiLinks: scanned.wikiLinks,
            embeds: scanned.embeds,
            diagnosticHTML: HTMLFormatter.format(document),
            diagnostics: frontmatterResult.diagnostics
        )
    }

    private static func detectLineEnding(in source: String) -> LineEnding {
        let containsCRLF = source.contains("\r\n")
        let withoutCRLF = source.replacingOccurrences(of: "\r\n", with: "")
        let containsLF = withoutCRLF.contains("\n")

        switch (containsCRLF, containsLF) {
        case (false, false):
            return .none
        case (false, true):
            return .lf
        case (true, false):
            return .crlf
        case (true, true):
            return .mixed
        }
    }
}

extension String {
    fileprivate var removingLeadingBOM: String {
        guard first == "\u{FEFF}" else {
            return self
        }
        return String(dropFirst())
    }
}
