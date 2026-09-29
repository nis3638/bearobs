import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownSourcePatchBuilderTests: XCTestCase {
    func testUnchangedSourceProducesNoPatches() throws {
        let source = Data([0xEF, 0xBB, 0xBF]) + Data("正文\r\n".utf8)

        XCTAssertEqual(
            try MarkdownSourcePatchBuilder.makePatches(from: source, to: source),
            []
        )
    }

    func testSeparatedEditsProduceSeparateMinimalHunks() throws {
        let baseline = Data("alpha unchanged omega".utf8)
        let edited = Data("ALPHA unchanged OMEGA".utf8)

        let patches = try MarkdownSourcePatchBuilder.makePatches(
            from: baseline,
            to: edited
        )

        XCTAssertEqual(patches.count, 2)
        XCTAssertEqual(patches[0].range, 0..<5)
        XCTAssertEqual(patches[0].expectedOriginal, Data("alpha".utf8))
        XCTAssertEqual(patches[0].replacement, Data("ALPHA".utf8))
        XCTAssertEqual(patches[1].range, 16..<21)
        XCTAssertEqual(patches[1].expectedOriginal, Data("omega".utf8))
        XCTAssertEqual(patches[1].replacement, Data("OMEGA".utf8))
        XCTAssertEqual(
            try MarkdownSourcePatchApplier.apply(patches, to: baseline),
            edited
        )
    }

    func testHunksNeverSplitUnicodeScalars() throws {
        let baseline = Data("A😀e\u{301}Z".utf8)
        let edited = Data("A🐻éZ".utf8)

        let patches = try MarkdownSourcePatchBuilder.makePatches(
            from: baseline,
            to: edited
        )

        XCTAssertFalse(patches.isEmpty)
        for patch in patches {
            XCTAssertNotNil(String(data: patch.expectedOriginal, encoding: .utf8))
            XCTAssertNotNil(String(data: patch.replacement, encoding: .utf8))
        }
        XCTAssertEqual(
            try MarkdownSourcePatchApplier.apply(patches, to: baseline),
            edited
        )
    }

    func testInsertionsAndDeletionsRoundTripExactly() throws {
        let baseline = Data("prefix--middle--suffix\r\n".utf8)
        let edited = Data("prefix++middle-END-\r\n".utf8)

        let patches = try MarkdownSourcePatchBuilder.makePatches(
            from: baseline,
            to: edited
        )

        XCTAssertEqual(
            try MarkdownSourcePatchApplier.apply(patches, to: baseline),
            edited
        )
    }

    func testInvalidBaselineAndEditedUTF8AreRejected() {
        XCTAssertThrowsError(
            try MarkdownSourcePatchBuilder.makePatches(
                from: Data([0xFF]),
                to: Data("valid".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .invalidUTF8Source)
        }
        XCTAssertThrowsError(
            try MarkdownSourcePatchBuilder.makePatches(
                from: Data("valid".utf8),
                to: Data([0xFF])
            )
        ) { error in
            XCTAssertEqual(error as? MarkdownSourcePatchError, .invalidUTF8Replacement)
        }
    }

    func testDiverseRepeatedAndMultibyteEditsAlwaysRoundTrip() throws {
        let cases = [
            ("aaaaabaaaaa", "aaa🐻abaaaZaa"),
            ("\u{FEFF}alpha😀beta", "\u{FEFF}ALPHA😀beta!"),
            ("重复重复重复", "重复新重复"),
            ("e\u{301}e\u{301}e\u{301}", "ée\u{301}🐻"),
            ("one\r\ntwo\r\nthree\r\n", "ONE\r\ntwo\r\nTHREE\r\n"),
            ("delete everything", ""),
            ("", "insert 全部 😀"),
        ]

        for (original, replacement) in cases {
            let baseline = Data(original.utf8)
            let edited = Data(replacement.utf8)
            let patches = try MarkdownSourcePatchBuilder.makePatches(
                from: baseline,
                to: edited
            )

            XCTAssertEqual(
                try MarkdownSourcePatchApplier.apply(patches, to: baseline),
                edited,
                "Failed to round-trip \(original.debugDescription)"
            )
        }
    }

    func testMaximumSizedNoteWithOneEditDoesNotBecomeAWholeDocumentPatch() throws {
        let prefix = String(repeating: "a", count: 512 * 1_024)
        let suffix = String(repeating: "z", count: 512 * 1_024 - 1)
        let baseline = Data((prefix + "b" + suffix).utf8)
        let edited = Data((prefix + "熊" + suffix).utf8)

        let patches = try MarkdownSourcePatchBuilder.makePatches(
            from: baseline,
            to: edited
        )

        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].range.count, 1)
        XCTAssertEqual(patches[0].replacement, Data("熊".utf8))
        XCTAssertEqual(
            try MarkdownSourcePatchApplier.apply(patches, to: baseline),
            edited
        )
    }

    func testLargeCompletelyDifferentTextUsesBoundedFallback() throws {
        let baseline = Data(String(repeating: "a", count: 100_000).utf8)
        let edited = Data(String(repeating: "b", count: 100_000).utf8)

        let patches = try MarkdownSourcePatchBuilder.makePatches(
            from: baseline,
            to: edited
        )

        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(patches[0].range, 0..<baseline.count)
        XCTAssertEqual(patches[0].replacement, edited)
        XCTAssertEqual(
            try MarkdownSourcePatchApplier.apply(patches, to: baseline),
            edited
        )
    }

    func testManySeparatedSubstitutionsRemainSeparatePatches() throws {
        let baselineText = (0..<129).map { "x\($0)-stable-" }.joined()
        let editedText = baselineText.replacingOccurrences(of: "x", with: "y")
        let baseline = Data(baselineText.utf8)
        let edited = Data(editedText.utf8)

        let patches = try MarkdownSourcePatchBuilder.makePatches(
            from: baseline,
            to: edited
        )

        XCTAssertEqual(patches.count, 129)
        XCTAssertTrue(patches.allSatisfy { $0.range.count == 1 })
        XCTAssertEqual(
            try MarkdownSourcePatchApplier.apply(patches, to: baseline),
            edited
        )
    }
}
