import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class VerifierPathTests: XCTestCase {
    func testRejectsUnsafeDecodedPaths() {
        let invalid = [
            "", "/absolute", "a\\b", "a//b", ".", "..", "a/./b", "a/../b", "a\0b",
        ]

        for value in invalid {
            XCTAssertThrowsError(try VerifierPath(decodedRelativePath: value), value)
        }
    }

    func testRejectsMalformedOrSeparatorProducingPercentEncoding() {
        for value in ["bad%", "bad%2", "bad%GG", "%2F", "a/%5C/b"] {
            XCTAssertThrowsError(try VerifierPath(percentEncodedRelativePath: value), value)
        }
    }

    func testNormalizesUnicodeAndEncodesEachComponentExactlyOnce() throws {
        let decomposed = "Cafe\u{301} 空格%/二.md"
        let path = try VerifierPath(decodedRelativePath: decomposed)

        XCTAssertEqual(path.description, "Café 空格%/二.md")
        XCTAssertEqual(
            path.percentEncodedRelativePath,
            "Caf%C3%A9%20%E7%A9%BA%E6%A0%BC%25/%E4%BA%8C.md"
        )
        XCTAssertEqual(
            try VerifierPath(percentEncodedRelativePath: path.percentEncodedRelativePath),
            path
        )
        XCTAssertEqual(
            try VerifierPath(decodedRelativePath: "literal%25.md").percentEncodedRelativePath,
            "literal%2525.md"
        )
    }
}
