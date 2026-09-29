import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class MarkdownTextCoordinateMapTests: XCTestCase {
    func testMapsUTF8RangesToUTF16WithoutSplittingUnicodeScalars() throws {
        let text = "A😀e\u{0301}\r\n中"
        let map = MarkdownTextCoordinateMap(text: text)

        XCTAssertEqual(map.utf16Range(forUTF8: 0..<1), 0..<1)
        XCTAssertEqual(map.utf16Range(forUTF8: 1..<5), 1..<3)
        XCTAssertEqual(map.utf16Range(forUTF8: 5..<8), 3..<5)
        XCTAssertEqual(map.utf16Range(forUTF8: 8..<10), 5..<7)
        XCTAssertEqual(map.utf16Range(forUTF8: 10..<13), 7..<8)

        XCTAssertNil(map.utf16Range(forUTF8: 2..<5))
        XCTAssertNil(map.utf16Range(forUTF8: 5..<7))
    }

    func testMapsUTF16OffsetsBackToUTF8AtScalarBoundariesOnly() throws {
        let text = "A😀e\u{0301}\r\n中"
        let map = MarkdownTextCoordinateMap(text: text)

        XCTAssertEqual(map.utf8Offset(forUTF16: 0), 0)
        XCTAssertEqual(map.utf8Offset(forUTF16: 1), 1)
        XCTAssertEqual(map.utf8Offset(forUTF16: 3), 5)
        XCTAssertEqual(map.utf8Offset(forUTF16: 5), 8)
        XCTAssertEqual(map.utf8Offset(forUTF16: 8), 13)

        XCTAssertNil(map.utf8Offset(forUTF16: 2))
    }

    func testMapsEmptyRangesAndRejectsOutOfBoundsCoordinates() throws {
        let map = MarkdownTextCoordinateMap(text: "中文")

        XCTAssertEqual(map.utf16Range(forUTF8: 0..<0), 0..<0)
        XCTAssertEqual(map.utf16Range(forUTF8: 3..<3), 1..<1)
        XCTAssertNil(map.utf16Range(forUTF8: -1..<0))
        XCTAssertNil(map.utf16Range(forUTF8: 0..<4))
        XCTAssertNil(map.utf8Offset(forUTF16: -1))
        XCTAssertNil(map.utf8Offset(forUTF16: 3))
    }

    func testRoundTripsEveryScalarBoundaryAcrossScriptsAndLineEndings() {
        let text = "\u{feff}中文😀e\u{0301}\n行二\r\n\r"
        let map = MarkdownTextCoordinateMap(text: text)

        var utf8Offset = 0
        var utf16Offset = 0
        for scalar in text.unicodeScalars {
            let previousUTF8 = utf8Offset
            let previousUTF16 = utf16Offset
            utf8Offset += scalar.utf8.count
            utf16Offset += scalar.utf16.count

            XCTAssertEqual(
                map.utf16Range(forUTF8: previousUTF8..<utf8Offset),
                previousUTF16..<utf16Offset,
                "scalar \(scalar) did not round-trip forward")
            XCTAssertEqual(
                map.utf8Offset(forUTF16: utf16Offset),
                utf8Offset,
                "scalar \(scalar) did not round-trip backward")
        }
        XCTAssertEqual(utf8Offset, text.utf8.count)
        XCTAssertEqual(utf16Offset, text.utf16.count)
    }
}
