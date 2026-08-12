import Foundation

/// A validated, normalized path relative to the verifier's dedicated WebDAV root.
public struct VerifierPath: Hashable, Sendable, CustomStringConvertible, Codable {
    private let decodedRelativePath: String

    /// Creates a path from decoded text.
    ///
    /// The path is normalized to Unicode NFC. Empty components, traversal components,
    /// absolute paths, backslashes, and control characters are rejected.
    public init(decodedRelativePath: String) throws {
        let normalized = decodedRelativePath.precomposedStringWithCanonicalMapping
        try Self.validateDecodedPath(normalized)
        self.decodedRelativePath = normalized
    }

    /// Creates a path from an RFC 3986-style percent-encoded relative path.
    ///
    /// Each component is decoded independently. This is deliberate: an encoded slash
    /// or backslash must never be able to create a new path boundary.
    public init(percentEncodedRelativePath: String) throws {
        guard !percentEncodedRelativePath.isEmpty else {
            throw VerifierPathError.emptyPath
        }
        guard !percentEncodedRelativePath.hasPrefix("/") else {
            throw VerifierPathError.absolutePath
        }

        let encodedComponents = percentEncodedRelativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard encodedComponents.allSatisfy({ !$0.isEmpty }) else {
            throw VerifierPathError.emptyComponent
        }

        let decodedComponents = try encodedComponents.map { encodedComponent in
            let component = try Self.decodePercentEncodedComponent(String(encodedComponent))
            guard !component.contains("/"), !component.contains("\\") else {
                throw VerifierPathError.encodedSeparator
            }
            return component
        }

        try self.init(decodedRelativePath: decodedComponents.joined(separator: "/"))
    }

    public var description: String {
        decodedRelativePath
    }

    /// The canonical percent-encoded representation, with path separators preserved.
    public var percentEncodedRelativePath: String {
        decodedRelativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { Self.encodeComponent(String($0)) }
            .joined(separator: "/")
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)

        do {
            try self.init(decodedRelativePath: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid verifier-relative path"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(decodedRelativePath)
    }

    private static func validateDecodedPath(_ path: String) throws {
        guard !path.isEmpty else {
            throw VerifierPathError.emptyPath
        }
        guard !path.hasPrefix("/") else {
            throw VerifierPathError.absolutePath
        }
        guard !path.contains("\\") else {
            throw VerifierPathError.backslash
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard !component.isEmpty else {
                throw VerifierPathError.emptyComponent
            }
            guard component != ".", component != ".." else {
                throw VerifierPathError.traversalComponent
            }
            guard !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            else {
                throw VerifierPathError.controlCharacter
            }
        }
    }

    private static func decodePercentEncodedComponent(_ component: String) throws -> String {
        let source = Array(component.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(source.count)

        var index = 0
        while index < source.count {
            guard source[index] == asciiPercent else {
                decoded.append(source[index])
                index += 1
                continue
            }

            guard index + 2 < source.count,
                let high = hexadecimalValue(source[index + 1]),
                let low = hexadecimalValue(source[index + 2])
            else {
                throw VerifierPathError.malformedPercentEncoding
            }

            decoded.append((high << 4) | low)
            index += 3
        }

        guard let result = String(bytes: decoded, encoding: .utf8) else {
            throw VerifierPathError.invalidUTF8
        }
        return result
    }

    private static func encodeComponent(_ component: String) -> String {
        let hexadecimalDigits = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(component.utf8.count)

        for byte in component.utf8 {
            if isUnreserved(byte) {
                encoded.append(byte)
            } else {
                encoded.append(asciiPercent)
                encoded.append(hexadecimalDigits[Int(byte >> 4)])
                encoded.append(hexadecimalDigits[Int(byte & 0x0F)])
            }
        }

        return String(decoding: encoded, as: UTF8.self)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57:
            byte - 48
        case 65...70:
            byte - 55
        case 97...102:
            byte - 87
        default:
            nil
        }
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 65...90, 97...122, 48...57, 45, 46, 95, 126:
            true
        default:
            false
        }
    }

    private static let asciiPercent: UInt8 = 0x25
}

public enum VerifierPathError: Error, Equatable, Sendable {
    case emptyPath
    case absolutePath
    case emptyComponent
    case traversalComponent
    case backslash
    case controlCharacter
    case malformedPercentEncoding
    case invalidUTF8
    case encodedSeparator
}
