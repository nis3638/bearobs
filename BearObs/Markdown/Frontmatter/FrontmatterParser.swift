import CYaml
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
    case resourceLimit = "frontmatter.resource-limit"
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

enum FrontmatterParser {
    static func parse(_ data: Data) throws -> FrontmatterParseResult {
        try parse(data, limits: .unbounded)
    }

    static func parse(
        _ data: Data,
        limits: FrontmatterResourceLimits
    ) throws -> FrontmatterParseResult {
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
                let yamlRange = opening.nextOffset..<candidate.content.lowerBound
                guard yamlRange.count <= limits.maximumBytes else {
                    return resourceLimited(
                        data,
                        bodyStart: candidate.nextOffset
                    )
                }
                return parseYAML(
                    data.subdata(in: yamlRange),
                    bodyStart: candidate.nextOffset,
                    originalData: data,
                    limits: limits
                )
            }
            offset = candidate.nextOffset
        }

        return result(data, state: .invalid, diagnostic: .unclosed)
    }
}

struct FrontmatterResourceLimits: Sendable, Equatable {
    let maximumBytes: Int
    let maximumNodes: Int
    let maximumDepth: Int
    let maximumAliases: Int
    let maximumTags: Int

    static let unbounded = FrontmatterResourceLimits(
        maximumBytes: .max,
        maximumNodes: .max,
        maximumDepth: .max,
        maximumAliases: .max,
        maximumTags: .max
    )
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
        originalData: Data,
        limits: FrontmatterResourceLimits
    ) -> FrontmatterParseResult {
        switch YAMLResourcePreflight.check(yamlData, limits: limits) {
        case .withinLimits:
            break
        case .invalidSyntax:
            return invalidYAML(originalData, bodyStart: bodyStart)
        case .limitExceeded:
            return resourceLimited(originalData, bodyStart: bodyStart)
        }
        do {
            guard let node = try Yams.compose(yaml: String(decoding: yamlData, as: UTF8.self))
            else {
                return result(originalData, bodyStart: bodyStart, state: .valid)
            }
            guard withinResourceLimits(node, limits: limits) else {
                return resourceLimited(originalData, bodyStart: bodyStart)
            }
            guard let mapping = node.any as? [String: Any] else {
                return invalidYAML(originalData, bodyStart: bodyStart)
            }
            guard let tags = tags(from: mapping["tags"], maximumCount: limits.maximumTags) else {
                return resourceLimited(originalData, bodyStart: bodyStart)
            }
            return result(
                originalData,
                bodyStart: bodyStart,
                state: .valid,
                title: nonemptyString(mapping["title"]),
                tags: tags
            )
        } catch {
            return invalidYAML(originalData, bodyStart: bodyStart)
        }
    }

    private static func withinResourceLimits(
        _ node: Node,
        limits: FrontmatterResourceLimits
    ) -> Bool {
        var remaining = limits.maximumNodes
        return consume(node, depth: 1, remaining: &remaining, maximumDepth: limits.maximumDepth)
    }

    private static func consume(
        _ node: Node,
        depth: Int,
        remaining: inout Int,
        maximumDepth: Int
    ) -> Bool {
        guard depth <= maximumDepth, remaining > 0 else {
            return false
        }
        remaining -= 1
        switch node {
        case .scalar, .alias:
            return true
        case .sequence(let sequence):
            return sequence.allSatisfy {
                consume($0, depth: depth + 1, remaining: &remaining, maximumDepth: maximumDepth)
            }
        case .mapping(let mapping):
            return mapping.allSatisfy { pair in
                consume(
                    pair.key, depth: depth + 1, remaining: &remaining, maximumDepth: maximumDepth)
                    && consume(
                        pair.value,
                        depth: depth + 1,
                        remaining: &remaining,
                        maximumDepth: maximumDepth
                    )
            }
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

    private static func resourceLimited(
        _ data: Data,
        bodyStart: Int
    ) -> FrontmatterParseResult {
        result(
            data,
            bodyStart: bodyStart,
            state: .invalid,
            diagnostic: .resourceLimit
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
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tags(from value: Any?, maximumCount: Int) -> [String]? {
        if let string = value as? String {
            var result: [String] = []
            for value in string.split(separator: ",") {
                guard result.count < maximumCount else { return nil }
                if let tag = nonemptyString(String(value)) {
                    result.append(tag)
                }
            }
            return result
        }
        if let sequence = value as? [Any] {
            var result: [String] = []
            for value in sequence {
                guard result.count < maximumCount else { return nil }
                if let tag = nonemptyString(value) {
                    result.append(tag)
                }
            }
            return result
        }
        return []
    }
}

private enum YAMLResourcePreflight {
    enum Outcome {
        case withinLimits
        case invalidSyntax
        case limitExceeded
    }

    static func check(_ data: Data, limits: FrontmatterResourceLimits) -> Outcome {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) != 0 else {
            return .limitExceeded
        }
        defer { yaml_parser_delete(&parser) }

        var nodes = 0
        var aliases = 0
        var depth = 0

        return data.withUnsafeBytes { rawBuffer in
            yaml_parser_set_input_string(
                &parser,
                rawBuffer.bindMemory(to: UInt8.self).baseAddress,
                rawBuffer.count
            )
            while true {
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) != 0 else {
                    return .invalidSyntax
                }
                let type = event.type
                yaml_event_delete(&event)

                switch type {
                case YAML_ALIAS_EVENT:
                    nodes += 1
                    aliases += 1
                case YAML_SCALAR_EVENT:
                    nodes += 1
                case YAML_SEQUENCE_START_EVENT, YAML_MAPPING_START_EVENT:
                    nodes += 1
                    depth += 1
                case YAML_SEQUENCE_END_EVENT, YAML_MAPPING_END_EVENT:
                    depth -= 1
                case YAML_STREAM_END_EVENT:
                    return .withinLimits
                default:
                    break
                }
                guard
                    nodes <= limits.maximumNodes,
                    depth <= limits.maximumDepth,
                    aliases <= limits.maximumAliases
                else {
                    return .limitExceeded
                }
            }
        }
    }
}
