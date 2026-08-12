import Foundation
import Yams

public enum FrontmatterState: Sendable, Equatable {
    case absent
    case valid
    case invalid
}

public enum FrontmatterDiagnostic: String, Sendable, Equatable {
    case invalidYAML = "frontmatter.invalid-yaml"
    case unclosed = "frontmatter.unclosed"
}

public enum FrontmatterParseError: Error, Sendable, Equatable {
    case invalidUTF8
}

public struct FrontmatterParseResult: Sendable, Equatable {
    public let originalData: Data
    public let bodyRange: Range<Int>
    public let state: FrontmatterState
    public let title: String?
    public let tags: [String]
    public let diagnostic: FrontmatterDiagnostic?

    public var bodyData: Data {
        originalData.subdata(in: bodyRange)
    }

    init(
        originalData: Data,
        bodyRange: Range<Int>,
        state: FrontmatterState,
        title: String? = nil,
        tags: [String] = [],
        diagnostic: FrontmatterDiagnostic? = nil
    ) {
        self.originalData = originalData
        self.bodyRange = bodyRange
        self.state = state
        self.title = title
        self.tags = tags
        self.diagnostic = diagnostic
    }
}

public enum FrontmatterParser {
    public static func parse(_ data: Data) throws -> FrontmatterParseResult {
        guard String(data: data, encoding: .utf8) != nil else {
            throw FrontmatterParseError.invalidUTF8
        }

        let bytes = Array(data)
        let contentStart = bytes.starts(with: utf8BOM) ? utf8BOM.count : 0
        let opening = line(at: contentStart, in: bytes)

        guard delimiter(in: opening, bytes: bytes) else {
            return result(data, state: .absent)
        }

        var offset = opening.nextOffset
        while offset < bytes.count {
            let candidate = line(at: offset, in: bytes)
            if delimiter(in: candidate, bytes: bytes) {
                return parseYAML(
                    data.subdata(in: opening.nextOffset..<candidate.content.lowerBound),
                    bodyStart: candidate.nextOffset,
                    originalData: data
                )
            }
            offset = candidate.nextOffset
        }

        return result(data, state: .invalid, diagnostic: .unclosed)
    }
}

extension FrontmatterParser {
    private struct Line {
        let content: Range<Int>
        let nextOffset: Int
    }

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let delimiterBytes: [UInt8] = Array("---".utf8)

    private static func line(at start: Int, in bytes: [UInt8]) -> Line {
        guard let newline = bytes[start...].firstIndex(of: 0x0A) else {
            return Line(content: start..<bytes.count, nextOffset: bytes.count)
        }

        let contentEnd =
            newline > start && bytes[newline - 1] == 0x0D
            ? newline - 1
            : newline
        return Line(content: start..<contentEnd, nextOffset: newline + 1)
    }

    private static func delimiter(in line: Line, bytes: [UInt8]) -> Bool {
        bytes[line.content].elementsEqual(delimiterBytes)
    }

    private static func parseYAML(
        _ yamlData: Data,
        bodyStart: Int,
        originalData: Data
    ) -> FrontmatterParseResult {
        do {
            guard let object = try Yams.load(yaml: String(decoding: yamlData, as: UTF8.self)) else {
                return result(originalData, bodyStart: bodyStart, state: .valid)
            }
            guard let mapping = object as? [String: Any] else {
                return invalidYAML(originalData, bodyStart: bodyStart)
            }
            return result(
                originalData,
                bodyStart: bodyStart,
                state: .valid,
                title: nonemptyString(mapping["title"]),
                tags: tags(from: mapping["tags"])
            )
        } catch {
            return invalidYAML(originalData, bodyStart: bodyStart)
        }
    }

    private static func invalidYAML(
        _ data: Data,
        bodyStart: Int
    ) -> FrontmatterParseResult {
        result(
            data,
            bodyStart: bodyStart,
            state: .invalid,
            diagnostic: .invalidYAML
        )
    }

    private static func result(
        _ data: Data,
        bodyStart: Int = 0,
        state: FrontmatterState,
        title: String? = nil,
        tags: [String] = [],
        diagnostic: FrontmatterDiagnostic? = nil
    ) -> FrontmatterParseResult {
        FrontmatterParseResult(
            originalData: data,
            bodyRange: bodyStart..<data.count,
            state: state,
            title: title,
            tags: tags,
            diagnostic: diagnostic
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
