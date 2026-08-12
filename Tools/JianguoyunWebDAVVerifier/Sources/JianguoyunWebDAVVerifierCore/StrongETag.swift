import Foundation

public enum ETagClassification: String, Codable, Equatable, Sendable {
    case missing
    case weak
    case wildcard
    case malformed
    case strong
}

/// Classifies a single HTTP entity-tag field value.
public enum ETagClassifier {
    public static func classify(_ headerValue: String?) -> ETagClassification {
        guard let headerValue else {
            return .missing
        }

        let value = trimOptionalWhitespace(headerValue)
        if value == "*" {
            return .wildcard
        }
        if value.hasPrefix("W/") {
            return isValidOpaqueTag(String(value.dropFirst(2))) ? .weak : .malformed
        }
        return isValidOpaqueTag(value) ? .strong : .malformed
    }

    fileprivate static func normalizedStrongValue(_ headerValue: String) -> String? {
        let normalized = trimOptionalWhitespace(headerValue)
        guard classify(normalized) == .strong else {
            return nil
        }
        return normalized
    }

    private static func trimOptionalWhitespace(_ value: String) -> String {
        value.trimmingCharacters(in: optionalWhitespace)
    }

    private static func isValidOpaqueTag(_ value: String) -> Bool {
        guard value.first == "\"", value.last == "\"", value.count >= 2 else {
            return false
        }

        return value.dropFirst().dropLast().unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x21, 0x23...0x7E, 0x80...0xFF:
                true
            default:
                false
            }
        }
    }

    private static let optionalWhitespace = CharacterSet(charactersIn: " \t")
}

/// A syntactically valid strong HTTP entity-tag suitable for `If-Match`.
public struct StrongETag: Hashable, Sendable, Codable {
    public let headerValue: String

    public init(headerValue: String) throws {
        guard let normalized = ETagClassifier.normalizedStrongValue(headerValue) else {
            throw StrongETagError.notStrong
        }
        self.headerValue = normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        do {
            try self.init(headerValue: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected one valid strong entity-tag"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(headerValue)
    }
}

public enum StrongETagError: Error, Equatable, Sendable {
    case notStrong
}
