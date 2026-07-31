import Foundation
import Yams

struct FrontmatterProbe {
    struct Result {
        let body: String
        let frontmatter: MarkdownSpike.Frontmatter
        let diagnostics: [String]
    }

    static func parse(_ source: String) -> Result {
        let normalizedSource = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedSource.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)

        guard lines.first == "---" else {
            return Result(
                body: normalizedSource,
                frontmatter: .init(state: .absent, title: nil, tags: []),
                diagnostics: []
            )
        }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return Result(
                body: normalizedSource,
                frontmatter: .init(state: .invalid, title: nil, tags: []),
                diagnostics: ["frontmatter.unclosed"]
            )
        }

        let yaml = lines[1..<closingIndex].joined(separator: "\n")
        let body = lines.dropFirst(closingIndex + 1).joined(separator: "\n")

        do {
            let object = try Yams.load(yaml: yaml)
            if object == nil {
                return Result(
                    body: body,
                    frontmatter: .init(state: .valid, title: nil, tags: []),
                    diagnostics: []
                )
            }
            guard let mapping = object as? [String: Any] else {
                return invalidYAML(body: body)
            }
            return Result(
                body: body,
                frontmatter: .init(
                    state: .valid,
                    title: nonemptyString(mapping["title"]),
                    tags: tags(from: mapping["tags"])
                ),
                diagnostics: []
            )
        } catch {
            return invalidYAML(body: body)
        }
    }

    private static func invalidYAML(body: String) -> Result {
        Result(
            body: body,
            frontmatter: .init(state: .invalid, title: nil, tags: []),
            diagnostics: ["frontmatter.invalid-yaml"]
        )
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tags(from value: Any?) -> [String] {
        if let string = value as? String {
            return string.split(separator: ",").compactMap {
                nonemptyString(String($0))
            }
        }
        if let values = value as? [Any] {
            return values.compactMap(nonemptyString)
        }
        return []
    }
}
