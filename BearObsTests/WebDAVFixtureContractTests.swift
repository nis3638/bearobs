import Foundation
import XCTest

final class WebDAVFixtureContractTests: XCTestCase {
    private var fixture: ControlledWebDAVFixture!
    private var session: URLSession!

    override func setUpWithError() throws {
        let root = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "WebDAV", withExtension: nil)
        )
        fixture = try ControlledWebDAVFixture(root: root)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledWebDAVURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session?.invalidateAndCancel()
        fixture?.shutdown()
        session = nil
        fixture = nil
    }

    func testPROPFINDDepthOneReturnsGolden207Response() async throws {
        var request = URLRequest(url: fixture.url(percentEncodedPath: "/vault/"))
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")

        let (data, response) = try await session.data(for: request)
        let http = try httpResponse(response)
        let expected = try Data(
            contentsOf: fixture.root.appendingPathComponent("responses/propfind-depth-1.xml")
        )
        let xml = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(http.statusCode, 207)
        XCTAssertEqual(
            http.value(forHTTPHeaderField: "Content-Type"), "application/xml; charset=utf-8")
        XCTAssertEqual(data, expected)
        XCTAssertTrue(xml.contains("/vault/Unicode/"))
        XCTAssertFalse(xml.contains("/vault/Unicode/%E7%A9%BA%20%E6%A0%BC%25.md"))
    }

    func testPROPFINDRejectsUnsupportedDepth() async throws {
        var request = URLRequest(url: fixture.url(percentEncodedPath: "/vault/"))
        request.httpMethod = "PROPFIND"
        request.setValue("infinity", forHTTPHeaderField: "Depth")

        let (_, response) = try await session.data(for: request)

        XCTAssertEqual(try httpResponse(response).statusCode, 400)
    }

    func testGETReturnsExactBytesAndValidators() async throws {
        let url = fixture.url(percentEncodedPath: "/vault/note.md")

        let (data, response) = try await session.data(from: url)
        let http = try httpResponse(response)
        let expected = try Data(
            contentsOf: fixture.root.appendingPathComponent("vault/note.md")
        )

        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(data, expected)
        XCTAssertEqual(http.value(forHTTPHeaderField: "ETag"), #""note-v1""#)
        XCTAssertEqual(
            http.value(forHTTPHeaderField: "Content-Length"),
            String(expected.count)
        )
    }

    func testMatchingIfMatchPUTReplacesBodyAndAdvancesETag() async throws {
        let url = fixture.url(percentEncodedPath: "/vault/note.md")
        let replacement = Data("# Updated synthetic note\n".utf8)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = replacement
        request.setValue(#""note-v1""#, forHTTPHeaderField: "If-Match")

        let (_, putResponse) = try await session.data(for: request)
        let (stored, getResponse) = try await session.data(from: url)

        XCTAssertEqual(try httpResponse(putResponse).statusCode, 204)
        XCTAssertEqual(stored, replacement)
        XCTAssertEqual(
            try httpResponse(getResponse).value(forHTTPHeaderField: "ETag"),
            #""note-v2""#
        )
    }

    func testStaleIfMatchReturns412AndPreservesResource() async throws {
        let url = fixture.url(percentEncodedPath: "/vault/note.md")
        let (original, originalResponse) = try await session.data(from: url)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = Data("must never be stored".utf8)
        request.setValue(#""stale""#, forHTTPHeaderField: "If-Match")

        let (_, putResponse) = try await session.data(for: request)
        let (stored, storedResponse) = try await session.data(from: url)

        XCTAssertEqual(try httpResponse(putResponse).statusCode, 412)
        XCTAssertEqual(stored, original)
        XCTAssertEqual(
            try httpResponse(storedResponse).value(forHTTPHeaderField: "ETag"),
            try httpResponse(originalResponse).value(forHTTPHeaderField: "ETag")
        )
    }

    func testPUTWithoutConditionIsRejectedWithoutMutation() async throws {
        let url = fixture.url(percentEncodedPath: "/vault/note.md")
        let (original, _) = try await session.data(from: url)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = Data("unconditional overwrite".utf8)

        let (_, putResponse) = try await session.data(for: request)
        let (stored, _) = try await session.data(from: url)

        XCTAssertEqual(try httpResponse(putResponse).statusCode, 428)
        XCTAssertEqual(stored, original)
    }

    func testUnicodeSpaceAndLiteralPercentPathIsDecodedExactlyOnce() async throws {
        let encodedPath = "/vault/Unicode/%E7%A9%BA%20%E6%A0%BC%25.md"
        let url = fixture.url(percentEncodedPath: encodedPath)

        let (data, response) = try await session.data(from: url)

        XCTAssertEqual(try httpResponse(response).statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "# 空 格%\n")
        XCTAssertEqual(fixture.diagnostics().last?.percentEncodedPath, encodedPath)
    }

    func testInjected503IsOneShotAndDoesNotMutateResource() async throws {
        let path = "/vault/note.md"
        let url = fixture.url(percentEncodedPath: path)
        fixture.enqueue(
            .httpStatus(503, headers: ["Retry-After": "7"]),
            method: "GET",
            percentEncodedPath: path
        )

        let (_, failedResponse) = try await session.data(from: url)
        let (recovered, recoveredResponse) = try await session.data(from: url)

        XCTAssertEqual(try httpResponse(failedResponse).statusCode, 503)
        XCTAssertEqual(
            try httpResponse(failedResponse).value(forHTTPHeaderField: "Retry-After"),
            "7"
        )
        XCTAssertEqual(try httpResponse(recoveredResponse).statusCode, 200)
        XCTAssertEqual(
            recovered, try Data(contentsOf: fixture.root.appendingPathComponent("vault/note.md")))
    }

    func testInjectedTimeoutIsOneShotAndNextRequestRecovers() async throws {
        let path = "/vault/note.md"
        let url = fixture.url(percentEncodedPath: path)
        fixture.enqueue(
            .urlError(.timedOut),
            method: "GET",
            percentEncodedPath: path
        )

        do {
            _ = try await session.data(from: url)
            XCTFail("Expected the configured timeout")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }

        let (_, response) = try await session.data(from: url)
        XCTAssertEqual(try httpResponse(response).statusCode, 200)
    }

    func testInterruptedGETDeliversConfiguredPrefixThenFails() async {
        let path = "/vault/note.md"
        let url = fixture.url(percentEncodedPath: path)
        fixture.enqueue(
            .interrupted(afterByteCount: 5, code: .networkConnectionLost),
            method: "GET",
            percentEncodedPath: path
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledWebDAVURLProtocol.self]
        let result = await ControlledWebDAVDataCapture().load(
            url: url,
            configuration: configuration
        )

        XCTAssertEqual(result.data, Data("# Syn".utf8))
        XCTAssertEqual((result.error as? URLError)?.code, .networkConnectionLost)
    }

    func testDiagnosticsNeverRecordAuthorizationQueryOrBody() async throws {
        let path = "/vault/note.md"
        let bodySecret = "private-body-sentinel"
        let querySecret = "private-query-sentinel"
        let credentialSecret = Data("fixture-user:fixture-password".utf8).base64EncodedString()
        var request = URLRequest(
            url: fixture.url(
                percentEncodedPath: path,
                percentEncodedQuery: "token=\(querySecret)"
            )
        )
        request.httpMethod = "PUT"
        request.httpBody = Data(bodySecret.utf8)
        request.setValue("Basic \(credentialSecret)", forHTTPHeaderField: "Authorization")
        request.setValue(#""stale""#, forHTTPHeaderField: "If-Match")

        _ = try await session.data(for: request)
        let diagnostics = fixture.diagnostics().map(\.description).joined(separator: "\n")

        XCTAssertFalse(diagnostics.contains(bodySecret))
        XCTAssertFalse(diagnostics.contains(querySecret))
        XCTAssertFalse(diagnostics.contains(credentialSecret))
        XCTAssertFalse(diagnostics.localizedCaseInsensitiveContains("authorization"))
        XCTAssertTrue(diagnostics.contains("bodyBytes=\(bodySecret.utf8.count)"))
    }

    private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        try XCTUnwrap(response as? HTTPURLResponse)
    }
}
