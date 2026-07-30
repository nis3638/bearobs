import Foundation

private enum BehaviorError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw BehaviorError.failed(message)
    }
}

private func httpResponse(_ response: URLResponse) throws -> HTTPURLResponse {
    guard let response = response as? HTTPURLResponse else {
        throw BehaviorError.failed("Fixture returned a non-HTTP response")
    }
    return response
}

@main
private struct WebDAVBehaviorVerifier {
    static func main() async throws {
        let root = fixtureRoot()
        try verifyFixturePathBoundary(sourceRoot: root)
        let fixture = try ControlledWebDAVFixture(root: root)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledWebDAVURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            fixture.shutdown()
        }

        try await verifyPROPFIND(fixture: fixture, session: session)
        try await verifyGETAndConditionalPUT(fixture: fixture, session: session)
        try await verifyEncodedPath(fixture: fixture, session: session)
        try await verifyFaults(fixture: fixture, session: session)
        try await verifyDiagnostics(fixture: fixture, session: session)

        print(
            "Verified WebDAV behavior: PROPFIND, GET, PUT, 412, faults, "
                + "path boundary, redaction."
        )
    }

    private static func fixtureRoot() -> URL {
        let script = URL(fileURLWithPath: #filePath)
        let repository = script.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repository.appendingPathComponent(
            "BearObsTests/Fixtures/WebDAV",
            isDirectory: true
        )
    }

    private static func verifyPROPFIND(
        fixture: ControlledWebDAVFixture,
        session: URLSession
    ) async throws {
        var request = URLRequest(url: fixture.url(percentEncodedPath: "/vault/"))
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")

        let (data, response) = try await session.data(for: request)
        let expected = try Data(
            contentsOf: fixture.root.appendingPathComponent(
                "responses/propfind-depth-1.xml"
            )
        )
        let http = try httpResponse(response)

        try require(http.statusCode == 207, "PROPFIND did not return 207")
        try require(data == expected, "PROPFIND response drifted from the golden XML")
    }

    private static func verifyFixturePathBoundary(sourceRoot: URL) throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "bearobs-webdav-boundary-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try requireRejectedFixture(
            sourceRoot: sourceRoot,
            destinationRoot: temporaryRoot.appendingPathComponent("traversal"),
            replacementBody: "../outside.md",
            symlinkTarget: nil
        )

        let outside = temporaryRoot.appendingPathComponent("outside.md")
        try Data("outside fixture root".utf8).write(to: outside)
        try requireRejectedFixture(
            sourceRoot: sourceRoot,
            destinationRoot: temporaryRoot.appendingPathComponent("symlink"),
            replacementBody: "vault/escape.md",
            symlinkTarget: outside
        )
    }

    private static func requireRejectedFixture(
        sourceRoot: URL,
        destinationRoot: URL,
        replacementBody: String,
        symlinkTarget: URL?
    ) throws {
        let fileManager = FileManager.default
        try fileManager.copyItem(at: sourceRoot, to: destinationRoot)
        let contractURL = destinationRoot.appendingPathComponent("contract.json")
        let original = String(decoding: try Data(contentsOf: contractURL), as: UTF8.self)
        let modified = original.replacingOccurrences(
            of: #""body": "vault/note.md""#,
            with: #""body": "\#(replacementBody)""#
        )
        try Data(modified.utf8).write(to: contractURL, options: .atomic)

        if let symlinkTarget {
            try fileManager.createSymbolicLink(
                at: destinationRoot.appendingPathComponent(replacementBody),
                withDestinationURL: symlinkTarget
            )
        }

        var rejected = false
        do {
            let fixture = try ControlledWebDAVFixture(root: destinationRoot)
            fixture.shutdown()
        } catch {
            rejected = true
        }
        try require(rejected, "Fixture accepted a resource outside its root")
    }

    private static func verifyGETAndConditionalPUT(
        fixture: ControlledWebDAVFixture,
        session: URLSession
    ) async throws {
        let url = fixture.url(percentEncodedPath: "/vault/note.md")
        let (original, originalResponse) = try await session.data(from: url)
        let originalHTTP = try httpResponse(originalResponse)
        try require(originalHTTP.statusCode == 200, "GET did not return 200")

        var stale = URLRequest(url: url)
        stale.httpMethod = "PUT"
        stale.httpBody = Data("must not be stored".utf8)
        stale.setValue(#""stale""#, forHTTPHeaderField: "If-Match")
        let (_, staleResponse) = try await session.data(for: stale)
        let (preserved, _) = try await session.data(from: url)
        let staleHTTP = try httpResponse(staleResponse)
        try require(staleHTTP.statusCode == 412, "Stale PUT did not return 412")
        try require(preserved == original, "Stale PUT mutated the resource")

        let replacement = Data("# Updated by behavior verifier\n".utf8)
        var matching = URLRequest(url: url)
        matching.httpMethod = "PUT"
        matching.httpBody = replacement
        matching.setValue(#""note-v1""#, forHTTPHeaderField: "If-Match")
        let (_, putResponse) = try await session.data(for: matching)
        let (stored, getResponse) = try await session.data(from: url)
        let putHTTP = try httpResponse(putResponse)
        let getHTTP = try httpResponse(getResponse)
        try require(putHTTP.statusCode == 204, "Matching PUT failed")
        try require(stored == replacement, "Matching PUT did not replace the resource")
        try require(
            getHTTP.value(forHTTPHeaderField: "ETag") == #""note-v2""#,
            "Matching PUT did not advance the ETag"
        )
    }

    private static func verifyEncodedPath(
        fixture: ControlledWebDAVFixture,
        session: URLSession
    ) async throws {
        let path = "/vault/Unicode/%E7%A9%BA%20%E6%A0%BC%25.md"
        let (data, response) = try await session.data(
            from: fixture.url(percentEncodedPath: path)
        )
        let http = try httpResponse(response)

        try require(http.statusCode == 200, "Encoded-path GET failed")
        try require(
            String(decoding: data, as: UTF8.self) == "# 空 格%\n", "Encoded path decoded twice")
    }

    private static func verifyFaults(
        fixture: ControlledWebDAVFixture,
        session: URLSession
    ) async throws {
        let path = "/vault/weak-etag.md"
        let url = fixture.url(percentEncodedPath: path)
        fixture.enqueue(
            .httpStatus(503, headers: ["Retry-After": "7"]),
            method: "GET",
            percentEncodedPath: path
        )

        let (_, unavailable) = try await session.data(from: url)
        let (_, recovered) = try await session.data(from: url)
        let unavailableHTTP = try httpResponse(unavailable)
        let recoveredHTTP = try httpResponse(recovered)
        try require(unavailableHTTP.statusCode == 503, "503 fault was not injected")
        try require(recoveredHTTP.statusCode == 200, "503 fault was not one-shot")

        fixture.enqueue(
            .httpStatus(401, headers: ["WWW-Authenticate": #"Basic realm="fixture""#]),
            method: "GET",
            percentEncodedPath: path
        )
        let (_, unauthorized) = try await session.data(from: url)
        let unauthorizedHTTP = try httpResponse(unauthorized)
        try require(unauthorizedHTTP.statusCode == 401, "401 fault was not injected")

        fixture.enqueue(
            .interrupted(afterByteCount: 5, code: .networkConnectionLost),
            method: "GET",
            percentEncodedPath: path
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledWebDAVURLProtocol.self]
        let interrupted = await ControlledWebDAVDataCapture().load(
            url: url,
            configuration: configuration
        )
        try require(interrupted.data == Data("# Wea".utf8), "Interrupted GET returned wrong prefix")
        try require(
            (interrupted.error as? URLError)?.code == .networkConnectionLost,
            "Interrupted GET returned the wrong error"
        )

        fixture.enqueue(
            .urlError(.timedOut),
            method: "GET",
            percentEncodedPath: path
        )
        do {
            _ = try await session.data(from: url)
            throw BehaviorError.failed("Timeout fault was not injected")
        } catch let error as URLError {
            try require(error.code == .timedOut, "Timeout fault returned the wrong error")
        }
    }

    private static func verifyDiagnostics(
        fixture: ControlledWebDAVFixture,
        session: URLSession
    ) async throws {
        let bodySecret = "behavior-private-body"
        let querySecret = "behavior-private-query"
        let credential = Data("fixture-user:fixture-password".utf8).base64EncodedString()
        var request = URLRequest(
            url: fixture.url(
                percentEncodedPath: "/vault/no-etag.md",
                percentEncodedQuery: "token=\(querySecret)"
            )
        )
        request.httpMethod = "PUT"
        request.httpBody = Data(bodySecret.utf8)
        request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")

        _ = try await session.data(for: request)
        let diagnostics = fixture.diagnostics().map(\.description).joined(separator: "\n")
        try require(!diagnostics.contains(bodySecret), "Diagnostics leaked request body")
        try require(!diagnostics.contains(querySecret), "Diagnostics leaked query value")
        try require(!diagnostics.contains(credential), "Diagnostics leaked credentials")
    }
}
