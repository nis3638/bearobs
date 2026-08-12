import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class FrontmatterParserTests: XCTestCase {
    func testGoldenStringAndArrayTagsAreReadWithoutChangingBytes() throws {
        let cases: [(String, String, [String])] = [
            (
                "Metadata/yaml-string.md",
                "Synthetic String Tags",
                ["alpha", "project/mobile", "中文"]
            ),
            (
                "Metadata/yaml-array.md",
                "Synthetic Array Tags",
                ["beta", "project/ios", "研发"]
            ),
        ]

        for (path, title, tags) in cases {
            let data = try goldenData(path)
            let result = try FrontmatterParser.parse(data)

            XCTAssertEqual(result.state, .valid, path)
            XCTAssertEqual(result.title, title, path)
            XCTAssertEqual(result.tags, tags, path)
            XCTAssertNil(result.diagnostic, path)
            XCTAssertEqual(result.originalData, data, path)
            XCTAssertTrue(
                String(decoding: result.bodyData, as: UTF8.self)
                    .hasPrefix("\n# "),
                path
            )
        }
    }

    func testMalformedYAMLReturnsDiagnosticAndPreservesReadableBody() throws {
        let data = try goldenData("Frontmatter/malformed-yaml.md")

        let result = try FrontmatterParser.parse(data)

        XCTAssertEqual(result.state, .invalid)
        XCTAssertEqual(result.diagnostic, .invalidYAML)
        XCTAssertNil(result.title)
        XCTAssertEqual(result.tags, [])
        XCTAssertTrue(
            String(decoding: result.bodyData, as: UTF8.self).contains("# Recoverable body"))
        XCTAssertEqual(result.originalData, data)
    }

    func testUnclosedFrontmatterKeepsEntireOriginalDocumentReadable() throws {
        let data = try goldenData("Frontmatter/unclosed.md")

        let result = try FrontmatterParser.parse(data)

        XCTAssertEqual(result.state, .invalid)
        XCTAssertEqual(result.diagnostic, .unclosed)
        XCTAssertEqual(result.bodyData, data)
        XCTAssertEqual(result.originalData, data)
    }

    func testAbsentAndEmptyFrontmatterAreDistinct() throws {
        let absent = Data("# Body\n".utf8)
        let empty = Data("---\n---\n# Body\n".utf8)

        let absentResult = try FrontmatterParser.parse(absent)
        let emptyResult = try FrontmatterParser.parse(empty)

        XCTAssertEqual(absentResult.state, .absent)
        XCTAssertEqual(absentResult.bodyData, absent)
        XCTAssertEqual(emptyResult.state, .valid)
        XCTAssertEqual(emptyResult.bodyData, Data("# Body\n".utf8))
        XCTAssertEqual(emptyResult.tags, [])
        XCTAssertNil(emptyResult.title)
    }

    func testBOMAndCRLFAreRecognizedWithoutNormalizingBodyBytes() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let source = Data("---\r\ntitle: CRLF\r\ntags: one, two\r\n---\r\n# Body\r\n".utf8)
        let data = bom + source

        let result = try FrontmatterParser.parse(data)

        XCTAssertEqual(result.state, .valid)
        XCTAssertEqual(result.title, "CRLF")
        XCTAssertEqual(result.tags, ["one", "two"])
        XCTAssertEqual(result.bodyData, Data("# Body\r\n".utf8))
        XCTAssertEqual(result.originalData, data)
    }

    func testOnlyExactOpeningAndClosingDelimiterLinesAreRecognized() throws {
        let notOpening = Data("--- extra\ntitle: Visible\n---\n# Body\n".utf8)
        let notClosing = Data("---\ntitle: Hidden\n--- extra\n# Body\n".utf8)

        let absentResult = try FrontmatterParser.parse(notOpening)
        let unclosedResult = try FrontmatterParser.parse(notClosing)

        XCTAssertEqual(absentResult.state, .absent)
        XCTAssertEqual(absentResult.bodyData, notOpening)
        XCTAssertEqual(unclosedResult.state, .invalid)
        XCTAssertEqual(unclosedResult.diagnostic, .unclosed)
        XCTAssertEqual(unclosedResult.bodyData, notClosing)
    }

    func testInvalidUTF8FailsExplicitly() {
        XCTAssertThrowsError(
            try FrontmatterParser.parse(Data([0xFF, 0xFE]))
        ) { error in
            XCTAssertEqual(error as? FrontmatterParseError, .invalidUTF8)
        }
    }
}

extension FrontmatterParserTests {
    fileprivate func goldenData(_ relativePath: String) throws -> Data {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle(for: Self.self)
        #endif
        let fixture = try XCTUnwrap(
            bundle.url(forResource: "GoldenVault", withExtension: nil)
        )
        return try Data(
            contentsOf:
                fixture
                .appendingPathComponent("vault", isDirectory: true)
                .appendingPathComponent(relativePath)
        )
    }
}
