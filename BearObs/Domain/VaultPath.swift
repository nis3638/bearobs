import Foundation

public struct VaultPath: Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible
{
    enum ValidationError: Error, Equatable, Sendable {
        case emptyPath
        case absolutePath
        case invalidSeparator
        case emptyComponent
        case traversalComponent
        case nullByte
        case invalidPercentEncoding
    }

    private let canonicalValue: String

    public init(decodedRelativePath: String) throws {
        canonicalValue = try Self.validate(decodedRelativePath)
    }

    public init(percentEncodedRelativePath: String) throws {
        let encodedParts = percentEncodedRelativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let decodedParts = try encodedParts.map(Self.decodeComponent)
        canonicalValue = try Self.validate(decodedParts.joined(separator: "/"))
    }

    public var description: String { canonicalValue }

    var components: [String] {
        canonicalValue.split(separator: "/").map(String.init)
    }

    var parent: VaultPath? {
        guard components.count > 1 else { return nil }
        return try? VaultPath(
            decodedRelativePath: components.dropLast().joined(separator: "/")
        )
    }

    var lastComponent: String {
        components.last!
    }

    var pathExtension: String? {
        guard
            let dot = lastComponent.lastIndex(of: "."),
            dot != lastComponent.startIndex,
            dot != lastComponent.index(before: lastComponent.endIndex)
        else {
            return nil
        }
        return String(lastComponent[lastComponent.index(after: dot)...])
    }

    var percentEncodedRelativePath: String {
        components.map(Self.encodeComponent).joined(separator: "/")
    }

    public static func < (lhs: VaultPath, rhs: VaultPath) -> Bool {
        lhs.canonicalValue < rhs.canonicalValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(decodedRelativePath: container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(canonicalValue)
    }

    private static func validate(_ input: String) throws -> String {
        guard !input.isEmpty else { throw ValidationError.emptyPath }
        guard !input.hasPrefix("/") else {
            throw ValidationError.absolutePath
        }
        guard !input.contains("\\") else {
            throw ValidationError.invalidSeparator
        }
        guard !input.contains("\0") else {
            throw ValidationError.nullByte
        }
        let canonical = input.precomposedStringWithCanonicalMapping
        let parts = canonical.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard parts.allSatisfy({ !$0.isEmpty }) else {
            throw ValidationError.emptyComponent
        }
        guard parts.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ValidationError.traversalComponent
        }
        return canonical
    }

    private static func decodeComponent(_ encoded: Substring) throws -> String {
        guard let decoded = String(encoded).removingPercentEncoding else {
            throw ValidationError.invalidPercentEncoding
        }
        guard !decoded.contains("/") && !decoded.contains("\\") else {
            throw ValidationError.invalidSeparator
        }
        return decoded
    }

    private static func encodeComponent(_ component: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var result = ""
        for byte in component.utf8 {
            if isUnreserved(byte) {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result.append("%")
                result.unicodeScalars.append(UnicodeScalar(hex[Int(byte >> 4)]))
                result.unicodeScalars.append(UnicodeScalar(hex[Int(byte & 0x0F)]))
            }
        }
        return result
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
            || (byte >= 48 && byte <= 57)
            || byte == 45
            || byte == 46
            || byte == 95
            || byte == 126
    }
}
