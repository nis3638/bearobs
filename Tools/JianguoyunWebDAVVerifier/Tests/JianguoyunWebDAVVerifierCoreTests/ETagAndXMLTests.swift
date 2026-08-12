import Foundation
import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class ETagAndXMLTests: XCTestCase {
    func testClassifiesStrongWeakMissingWildcardAndMalformedETags() throws {
        XCTAssertEqual(ETagClassifier.classify(nil), .missing)
        XCTAssertEqual(ETagClassifier.classify("W/\"weak\""), .weak)
        XCTAssertEqual(ETagClassifier.classify("*"), .wildcard)
        XCTAssertEqual(ETagClassifier.classify("not-quoted"), .malformed)
        XCTAssertEqual(ETagClassifier.classify("\"one\", \"two\""), .malformed)
        XCTAssertEqual(ETagClassifier.classify("\"opaque-value\""), .strong)
        XCTAssertEqual(
            try StrongETag(headerValue: "\"opaque-value\"").headerValue,
            "\"opaque-value\""
        )
        XCTAssertThrowsError(try StrongETag(headerValue: "W/\"weak\""))
    }

    func testNamespacePrefixAndElementOrderDoNotMatter() throws {
        let xml = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <x:multistatus xmlns:x="DAV:">
              <x:response>
                <x:propstat>
                  <x:status>HTTP/1.1 200 OK</x:status>
                  <x:prop>
                    <x:getetag>"v1"</x:getetag>
                    <x:resourcetype><x:collection/></x:resourcetype>
                  </x:prop>
                </x:propstat>
                <x:href>/dav/private-root/</x:href>
              </x:response>
            </x:multistatus>
            """.utf8
        )

        let result = try DAVMultiStatusParser().parse(xml)

        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries[0].href, "/dav/private-root/")
        XCTAssertEqual(result.entries[0].etagHeader, "\"v1\"")
        XCTAssertTrue(result.entries[0].isCollection)
    }

    func testFailedPropstatCannotBeMistakenForSuccess() {
        let xml = Data(
            """
            <d:multistatus xmlns:d="DAV:">
              <d:response>
                <d:href>/dav/private-root/a.md</d:href>
                <d:propstat>
                  <d:prop><d:getetag>"hidden"</d:getetag></d:prop>
                  <d:status>HTTP/1.1 404 Not Found</d:status>
                </d:propstat>
              </d:response>
            </d:multistatus>
            """.utf8
        )

        XCTAssertThrowsError(try DAVMultiStatusParser().parse(xml))
    }
}
