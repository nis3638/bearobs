import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownSourcePatchTests: XCTestCase {
    func testEmptyPatchReturnsTheOriginalBytesExactly() throws {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("标题\r\n正文".utf8)

        let result = try MarkdownSourcePatchApplier.apply([], to: source)

        XCTAssertEqual(result, source)
    }

    func testPatchUsesUTF8ByteOffsetsForMultibyteText() throws {
        let prefix = Data("前缀：".utf8)
        let original = Data("😀".utf8)
        let suffix = Data(" / 保持不变".utf8)
        let source = prefix + original + suffix
        let range = prefix.count..<(prefix.count + original.count)
        let patch = MarkdownSourcePatch(
            range: range,
            expectedOriginal: original,
            replacement: Data("🐻".utf8)
        )

        let result = try MarkdownSourcePatchApplier.apply([patch], to: source)

        XCTAssertEqual(range, 9..<13)
        XCTAssertEqual(result, prefix + Data("🐻".utf8) + suffix)
    }

    func testMultiplePatchesAreAppliedWithoutInvalidatingLaterByteRanges() throws {
        let prefix = Data("开始：".utf8)
        let firstOriginal = Data("猫".utf8)
        let middle = Data("；中间内容；".utf8)
        let secondOriginal = Data("🦊".utf8)
        let suffix = Data("：结束".utf8)
        let source = prefix + firstOriginal + middle + secondOriginal + suffix

        let firstRange = prefix.count..<(prefix.count + firstOriginal.count)
        let secondStart = prefix.count + firstOriginal.count + middle.count
        let secondRange = secondStart..<(secondStart + secondOriginal.count)
        let patches = [
            MarkdownSourcePatch(
                range: firstRange,
                expectedOriginal: firstOriginal,
                // Deliberately change the byte length so later ranges must be applied from the end.
                replacement: Data("熊猫".utf8)
            ),
            MarkdownSourcePatch(
                range: secondRange,
                expectedOriginal: secondOriginal,
                replacement: Data("狐".utf8)
            ),
        ]

        let result = try MarkdownSourcePatchApplier.apply(patches, to: source)

        XCTAssertEqual(
            result,
            prefix + Data("熊猫".utf8) + middle + Data("狐".utf8) + suffix
        )
    }

    func testOutOfBoundsRangeIsRejected() {
        let source = Data("abc".utf8)
        let patch = MarkdownSourcePatch(
            range: source.count..<(source.count + 1),
            expectedOriginal: Data([0x00]),
            replacement: Data("x".utf8)
        )

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply([patch], to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .invalidRange)
        }
    }

    func testExpectedOriginalBytesMustMatchTheSource() {
        let source = Data("abc".utf8)
        let patch = MarkdownSourcePatch(
            range: 1..<2,
            expectedOriginal: Data("x".utf8),
            replacement: Data("y".utf8)
        )

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply([patch], to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .expectedBytesMismatch)
        }
    }

    func testOverlappingRangesAreRejectedBeforeApplyingAnyPatch() {
        let source = Data("abcdef".utf8)
        let patches = [
            MarkdownSourcePatch(
                range: 0..<3,
                expectedOriginal: Data("abc".utf8),
                replacement: Data("ABC".utf8)
            ),
            MarkdownSourcePatch(
                range: 2..<5,
                expectedOriginal: Data("cde".utf8),
                replacement: Data("CDE".utf8)
            ),
        ]

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply(patches, to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .overlappingRanges)
        }
    }

    func testDuplicateInsertionsAtTheSameOffsetAreRejected() {
        let source = Data("abc".utf8)
        let patches = [
            MarkdownSourcePatch(
                range: 1..<1,
                expectedOriginal: Data(),
                replacement: Data("x".utf8)
            ),
            MarkdownSourcePatch(
                range: 1..<1,
                expectedOriginal: Data(),
                replacement: Data("y".utf8)
            ),
        ]

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply(patches, to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .overlappingRanges)
        }
    }

    func testInvalidUTF8SourceIsRejected() {
        let source = Data([0xFF])

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply([], to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .invalidUTF8Source)
        }
    }

    func testInvalidUTF8ReplacementIsRejected() {
        let source = Data("abc".utf8)
        let patch = MarkdownSourcePatch(
            range: 1..<2,
            expectedOriginal: Data("b".utf8),
            replacement: Data([0xFF])
        )

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply([patch], to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .invalidUTF8Replacement)
        }
    }

    func testInvalidUTF8ResultIsRejected() {
        let source = Data("😀".utf8)
        let patch = MarkdownSourcePatch(
            // Replacing one byte in the middle of a scalar makes the final source invalid UTF-8.
            range: 1..<2,
            expectedOriginal: source.subdata(in: 1..<2),
            replacement: Data("A".utf8)
        )

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply([patch], to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .invalidUTF8Result)
        }
    }

    func testAdjacentPatchesCannotHideInvalidUTF8SourceBoundaries() {
        let source = Data("😀".utf8)
        let patches = [
            MarkdownSourcePatch(
                range: 0..<1,
                expectedOriginal: source.subdata(in: 0..<1),
                replacement: Data()
            ),
            MarkdownSourcePatch(
                range: 1..<4,
                expectedOriginal: source.subdata(in: 1..<4),
                replacement: Data()
            ),
        ]

        XCTAssertThrowsError(try MarkdownSourcePatchApplier.apply(patches, to: source)) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .invalidRange)
        }
    }

    func testBytesOutsidePatchedRangeRemainUnchanged() throws {
        let prefix = Data([0xEF, 0xBB, 0xBF]) + Data("# 标题\r\n\r\n<!-- 注释 -->\r\n".utf8)
        let original = Data("正文中的词".utf8)
        let suffix = Data("\r\n\r\n未知语法::保持原样\n".utf8)
        let source = prefix + original + suffix
        let range = prefix.count..<(prefix.count + original.count)
        let patch = MarkdownSourcePatch(
            range: range,
            expectedOriginal: original,
            replacement: Data("正文中的新词".utf8)
        )

        let result = try MarkdownSourcePatchApplier.apply([patch], to: source)

        XCTAssertEqual(Data(result.prefix(prefix.count)), prefix)
        XCTAssertEqual(Data(result.suffix(suffix.count)), suffix)
        XCTAssertEqual(
            result,
            prefix + Data("正文中的新词".utf8) + suffix
        )
    }
}
