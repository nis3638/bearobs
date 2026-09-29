import Foundation

/// A replacement expressed against one immutable UTF-8 source snapshot.
public struct MarkdownSourcePatch: Equatable, Sendable {
    public let range: Range<Int>
    public let expectedOriginal: Data
    public let replacement: Data

    public init(
        range: Range<Int>,
        expectedOriginal: Data,
        replacement: Data
    ) {
        self.range = range
        self.expectedOriginal = expectedOriginal
        self.replacement = replacement
    }
}

public enum MarkdownSourcePatchError: Error, Equatable, Sendable {
    case invalidRange
    case expectedBytesMismatch
    case overlappingRanges
    case invalidUTF8Source
    case invalidUTF8Replacement
    case invalidUTF8Result
}

public enum MarkdownSourcePatchApplier {
    /// Applies patches atomically in memory. Every patch is validated against the
    /// original source before any replacement is made.
    public static func apply(
        _ patches: [MarkdownSourcePatch],
        to source: Data
    ) throws -> Data {
        guard String(data: source, encoding: .utf8) != nil else {
            throw MarkdownSourcePatchError.invalidUTF8Source
        }
        guard !patches.isEmpty else { return source }

        let hasInvalidSourceBoundary = try validate(patches, against: source)

        var result = source
        for patch in patches.sorted(by: descendingSourceOrder) {
            result.replaceSubrange(patch.range, with: patch.replacement)
        }
        guard String(data: result, encoding: .utf8) != nil else {
            throw MarkdownSourcePatchError.invalidUTF8Result
        }
        guard !hasInvalidSourceBoundary else {
            throw MarkdownSourcePatchError.invalidRange
        }
        return result
    }

    private static func validate(
        _ patches: [MarkdownSourcePatch],
        against source: Data
    ) throws -> Bool {
        let validBoundaries = utf8ScalarBoundaries(in: source)
        var hasInvalidSourceBoundary = false
        for patch in patches {
            guard
                patch.range.lowerBound >= 0,
                patch.range.upperBound >= patch.range.lowerBound,
                patch.range.upperBound <= source.count,
                patch.expectedOriginal.count == patch.range.count
            else {
                throw MarkdownSourcePatchError.invalidRange
            }
            guard String(data: patch.replacement, encoding: .utf8) != nil else {
                throw MarkdownSourcePatchError.invalidUTF8Replacement
            }
            guard source.subdata(in: patch.range) == patch.expectedOriginal else {
                throw MarkdownSourcePatchError.expectedBytesMismatch
            }
            hasInvalidSourceBoundary =
                hasInvalidSourceBoundary
                || !validBoundaries.contains(patch.range.lowerBound)
                || !validBoundaries.contains(patch.range.upperBound)
        }

        let ordered = patches.sorted(by: ascendingSourceOrder)
        for index in ordered.indices.dropFirst() {
            let previous = ordered[ordered.index(before: index)]
            let current = ordered[index]
            if current.range.lowerBound < previous.range.upperBound
                || (current.range.isEmpty
                    && previous.range.isEmpty
                    && current.range.lowerBound == previous.range.lowerBound)
            {
                throw MarkdownSourcePatchError.overlappingRanges
            }
        }
        return hasInvalidSourceBoundary
    }

    private static func utf8ScalarBoundaries(in source: Data) -> Set<Int> {
        let scalars = String(decoding: source, as: UTF8.self).unicodeScalars
        var boundaries: Set<Int> = [0]
        boundaries.reserveCapacity(scalars.count + 1)
        var offset = 0
        for scalar in scalars {
            offset += scalar.utf8.count
            boundaries.insert(offset)
        }
        return boundaries
    }

    private static func ascendingSourceOrder(
        _ lhs: MarkdownSourcePatch,
        _ rhs: MarkdownSourcePatch
    ) -> Bool {
        if lhs.range.lowerBound != rhs.range.lowerBound {
            return lhs.range.lowerBound < rhs.range.lowerBound
        }
        return lhs.range.upperBound < rhs.range.upperBound
    }

    private static func descendingSourceOrder(
        _ lhs: MarkdownSourcePatch,
        _ rhs: MarkdownSourcePatch
    ) -> Bool {
        if lhs.range.lowerBound != rhs.range.lowerBound {
            return lhs.range.lowerBound > rhs.range.lowerBound
        }
        return lhs.range.upperBound > rhs.range.upperBound
    }
}
