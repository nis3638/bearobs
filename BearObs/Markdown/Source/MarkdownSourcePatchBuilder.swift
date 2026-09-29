import Foundation

public enum MarkdownSourcePatchBuilder {
    /// Produces disjoint UTF-8 byte patches while retaining every unchanged byte.
    /// Diffing Unicode scalars prevents a patch boundary from splitting a scalar.
    public static func makePatches(
        from baseline: Data,
        to edited: Data
    ) throws -> [MarkdownSourcePatch] {
        guard String(data: baseline, encoding: .utf8) != nil else {
            throw MarkdownSourcePatchError.invalidUTF8Source
        }
        guard String(data: edited, encoding: .utf8) != nil else {
            throw MarkdownSourcePatchError.invalidUTF8Replacement
        }
        guard baseline != edited else { return [] }

        // String(data:encoding:) consumes a leading BOM. The BOM is content for
        // this byte diff, so decode only after validation with the preserving API.
        let baselineText = String(decoding: baseline, as: UTF8.self)
        let editedText = String(decoding: edited, as: UTF8.self)
        let original = ScalarSource(baselineText)
        let replacement = ScalarSource(editedText)
        guard detailedDiffIsAffordable(original.scalars, replacement.scalars) else {
            let patches =
                original.scalars.count == replacement.scalars.count
                ? positionalPatches(from: baseline, to: edited, original, replacement)
                : [coarsePatch(from: baseline, to: edited, original, replacement)]
            guard try MarkdownSourcePatchApplier.apply(patches, to: baseline) == edited else {
                throw MarkdownSourcePatchError.invalidUTF8Result
            }
            return patches
        }
        let difference = replacement.scalars.difference(from: original.scalars)
        let changedOffsets = ChangedOffsets(difference)

        var originalIndex = 0
        var replacementIndex = 0
        var patches: [MarkdownSourcePatch] = []

        while originalIndex < original.scalars.count
            || replacementIndex < replacement.scalars.count
        {
            let removes = changedOffsets.removals.contains(originalIndex)
            let inserts = changedOffsets.insertions.contains(replacementIndex)

            if !removes && !inserts {
                // CollectionDifference guarantees that the remaining paired values
                // are equal. Keeping this guard makes malformed internal state fail
                // closed instead of manufacturing a wrong source range.
                guard
                    originalIndex < original.scalars.count,
                    replacementIndex < replacement.scalars.count,
                    original.scalars[originalIndex]
                        == replacement.scalars[replacementIndex]
                else {
                    throw MarkdownSourcePatchError.invalidUTF8Result
                }
                originalIndex += 1
                replacementIndex += 1
                continue
            }

            let originalStart = originalIndex
            let replacementStart = replacementIndex
            repeat {
                if changedOffsets.removals.contains(originalIndex) {
                    originalIndex += 1
                }
                if changedOffsets.insertions.contains(replacementIndex) {
                    replacementIndex += 1
                }
            } while changedOffsets.removals.contains(originalIndex)
                || changedOffsets.insertions.contains(replacementIndex)

            let originalRange = Range(
                uncheckedBounds: (
                    original.byteOffsets[originalStart],
                    original.byteOffsets[originalIndex]
                )
            )
            let replacementRange = Range(
                uncheckedBounds: (
                    replacement.byteOffsets[replacementStart],
                    replacement.byteOffsets[replacementIndex]
                )
            )
            patches.append(
                MarkdownSourcePatch(
                    range: originalRange,
                    expectedOriginal: baseline.subdata(in: originalRange),
                    replacement: edited.subdata(in: replacementRange)
                )
            )
        }

        guard try MarkdownSourcePatchApplier.apply(patches, to: baseline) == edited else {
            throw MarkdownSourcePatchError.invalidUTF8Result
        }
        return patches
    }

    /// Swift's unbounded CollectionDifference has pathological behavior for a
    /// wholesale replacement. Probe the edit distance with a fixed budget first.
    /// Small, scattered edits keep precise hunks; large edits become one bounded
    /// replacement between their common scalar prefix and suffix.
    private static func detailedDiffIsAffordable(
        _ original: [Unicode.Scalar],
        _ replacement: [Unicode.Scalar]
    ) -> Bool {
        let limit = 256
        guard abs(original.count - replacement.count) <= limit else { return false }

        let maximumDistance = min(limit, original.count + replacement.count)
        let center = maximumDistance + 1
        var frontier = [Int](repeating: -1, count: maximumDistance * 2 + 3)
        frontier[center + 1] = 0

        for distance in 0...maximumDistance {
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                let slot = center + diagonal
                var originalOffset: Int
                if diagonal == -distance
                    || (diagonal != distance && frontier[slot - 1] < frontier[slot + 1])
                {
                    originalOffset = frontier[slot + 1]
                } else {
                    originalOffset = frontier[slot - 1] + 1
                }
                var replacementOffset = originalOffset - diagonal
                while originalOffset < original.count,
                    replacementOffset < replacement.count,
                    original[originalOffset] == replacement[replacementOffset]
                {
                    originalOffset += 1
                    replacementOffset += 1
                }
                frontier[slot] = originalOffset
                if originalOffset == original.count,
                    replacementOffset == replacement.count
                {
                    return true
                }
            }
        }
        return false
    }

    private static func coarsePatch(
        from baseline: Data,
        to edited: Data,
        _ original: ScalarSource,
        _ replacement: ScalarSource
    ) -> MarkdownSourcePatch {
        var commonPrefix = 0
        let commonCount = min(original.scalars.count, replacement.scalars.count)
        while commonPrefix < commonCount,
            original.scalars[commonPrefix] == replacement.scalars[commonPrefix]
        {
            commonPrefix += 1
        }

        var commonSuffix = 0
        while commonSuffix < original.scalars.count - commonPrefix,
            commonSuffix < replacement.scalars.count - commonPrefix,
            original.scalars[original.scalars.count - commonSuffix - 1]
                == replacement.scalars[replacement.scalars.count - commonSuffix - 1]
        {
            commonSuffix += 1
        }

        let originalStart = original.byteOffsets[commonPrefix]
        let originalEnd = original.byteOffsets[original.scalars.count - commonSuffix]
        let replacementStart = replacement.byteOffsets[commonPrefix]
        let replacementEnd = replacement.byteOffsets[replacement.scalars.count - commonSuffix]
        let originalRange = originalStart..<originalEnd
        let replacementRange = replacementStart..<replacementEnd
        return MarkdownSourcePatch(
            range: originalRange,
            expectedOriginal: baseline.subdata(in: originalRange),
            replacement: edited.subdata(in: replacementRange)
        )
    }

    private static func positionalPatches(
        from baseline: Data,
        to edited: Data,
        _ original: ScalarSource,
        _ replacement: ScalarSource
    ) -> [MarkdownSourcePatch] {
        var patches: [MarkdownSourcePatch] = []
        var index = 0
        while index < original.scalars.count {
            guard original.scalars[index] != replacement.scalars[index] else {
                index += 1
                continue
            }
            let start = index
            repeat {
                index += 1
            } while index < original.scalars.count
                && original.scalars[index] != replacement.scalars[index]

            let originalRange = original.byteOffsets[start]..<original.byteOffsets[index]
            let replacementRange = replacement.byteOffsets[start]..<replacement.byteOffsets[index]
            patches.append(
                MarkdownSourcePatch(
                    range: originalRange,
                    expectedOriginal: baseline.subdata(in: originalRange),
                    replacement: edited.subdata(in: replacementRange)
                )
            )
        }
        return patches
    }
}

extension MarkdownSourcePatchBuilder {
    private struct ScalarSource {
        let scalars: [Unicode.Scalar]
        let byteOffsets: [Int]

        init(_ text: String) {
            scalars = Array(text.unicodeScalars)
            var offsets = [0]
            offsets.reserveCapacity(scalars.count + 1)
            for scalar in scalars {
                offsets.append(offsets[offsets.count - 1] + scalar.utf8.count)
            }
            byteOffsets = offsets
        }
    }

    private struct ChangedOffsets {
        let removals: Set<Int>
        let insertions: Set<Int>

        init(_ difference: CollectionDifference<Unicode.Scalar>) {
            var removals: Set<Int> = []
            var insertions: Set<Int> = []
            for change in difference {
                switch change {
                case .remove(let offset, _, _):
                    removals.insert(offset)
                case .insert(let offset, _, _):
                    insertions.insert(offset)
                }
            }
            self.removals = removals
            self.insertions = insertions
        }
    }
}
