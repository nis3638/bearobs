import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsDomain
#else
    @testable import BearObs
#endif

final class VaultPathTests: XCTestCase {
    func testDecodedInputCanonicalizesUnicodeToNFC() throws {
        let decomposed = try VaultPath(
            decodedRelativePath: "Cafe\u{301}/笔记.md"
        )
        let composed = try VaultPath(decodedRelativePath: "Café/笔记.md")

        XCTAssertEqual(decomposed, composed)
        XCTAssertEqual(decomposed.description, "Café/笔记.md")
        XCTAssertEqual(Set([decomposed, composed]).count, 1)
    }

    func testPercentEncodedInputDecodesExactlyOnce() throws {
        XCTAssertEqual(
            try VaultPath(percentEncodedRelativePath: "空%20格.md").description,
            "空 格.md"
        )
        XCTAssertEqual(
            try VaultPath(
                percentEncodedRelativePath: "%252E%252E/note.md"
            ).description,
            "%2E%2E/note.md"
        )
    }

    func testDecodedAndEncodedFactoriesPreserveLiteralPercent() throws {
        let decoded = try VaultPath(
            decodedRelativePath: "Unicode/空 格%计划.md"
        )
        let encoded = try VaultPath(
            percentEncodedRelativePath: "Unicode/%E7%A9%BA%20%E6%A0%BC%25%E8%AE%A1%E5%88%92.md"
        )

        XCTAssertEqual(decoded, encoded)
        XCTAssertThrowsError(
            try VaultPath(percentEncodedRelativePath: "broken%path.md")
        )
        XCTAssertThrowsError(
            try VaultPath(percentEncodedRelativePath: "broken%A.md")
        )
    }

    func testRejectsInvalidDecodedPaths() {
        let invalidPaths = [
            "",
            "/absolute.md",
            "//host/share.md",
            "a//b.md",
            "a/",
            ".",
            "..",
            "a/./b.md",
            "a/../b.md",
            "a\\b.md",
            "a\0b.md",
        ]

        for path in invalidPaths {
            XCTAssertThrowsError(
                try VaultPath(decodedRelativePath: path),
                path
            )
        }
    }

    func testRejectsTraversalAfterPercentDecoding() {
        let invalidPaths = [
            "%2E%2E/note.md",
            "a/%2e/b.md",
            "%2Fabsolute.md",
            "a%2Fb.md",
            "a%2F%2E%2E%2Fb.md",
            "a%5C..%5Cb.md",
            "a%00b.md",
            "%FF.md",
        ]

        for path in invalidPaths {
            XCTAssertThrowsError(
                try VaultPath(percentEncodedRelativePath: path),
                path
            )
        }
    }

    func testCanonicalValueProperties() throws {
        let path = try VaultPath(decodedRelativePath: "Notes/a.test.md")
        let hidden = try VaultPath(decodedRelativePath: ".gitignore")
        let trailingDot = try VaultPath(decodedRelativePath: "note.")

        XCTAssertEqual(path.components, ["Notes", "a.test.md"])
        XCTAssertEqual(path.parent?.description, "Notes")
        XCTAssertEqual(path.lastComponent, "a.test.md")
        XCTAssertEqual(path.pathExtension, "md")
        XCTAssertEqual(
            try VaultPath(
                decodedRelativePath: "Unicode/空 格%计划.md"
            ).percentEncodedRelativePath,
            "Unicode/%E7%A9%BA%20%E6%A0%BC%25%E8%AE%A1%E5%88%92.md"
        )
        XCTAssertNil(hidden.parent)
        XCTAssertNil(hidden.pathExtension)
        XCTAssertNil(trailingDot.pathExtension)
        XCTAssertEqual(
            [path, hidden].sorted().map(\.description),
            [".gitignore", "Notes/a.test.md"]
        )
    }

    func testCodableUsesCanonicalStringAndRevalidatesInput() throws {
        let path = try VaultPath(decodedRelativePath: "Cafe\u{301}/笔记.md")
        let data = try JSONEncoder().encode(path)

        XCTAssertEqual(
            try JSONDecoder().decode(String.self, from: data),
            "Café/笔记.md"
        )
        XCTAssertEqual(try JSONDecoder().decode(VaultPath.self, from: data), path)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                VaultPath.self,
                from: Data("\"../escape.md\"".utf8)
            )
        )
    }
}
