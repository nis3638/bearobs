import Foundation
import Synchronization
import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class URLSessionWebDAVTransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OfflineURLProtocol.reset()
    }

    func testUnauthenticatedProbeUsesFixedRootWithoutAuthorization() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .http(
                responseURL: URL(string: "https://dav.jianguoyun.com/dav/private-root/"),
                statusCode: 401
            )
        )

        let statusCode = try await transport.unauthenticatedDepthZeroStatus()

        XCTAssertEqual(statusCode, 401)
        let request = try XCTUnwrap(OfflineURLProtocol.capturedRequests().only)
        XCTAssertEqual(request.url?.absoluteString, "https://dav.jianguoyun.com/dav/private-root/")
        XCTAssertEqual(request.method, "PROPFIND")
        XCTAssertEqual(request.header(named: "Depth"), "0")
        XCTAssertNil(request.header(named: "Authorization"))
        XCTAssertNil(request.body)
    }

    func testAuthenticatedRequestWaitsForChallengeBeforeSendingAuthorization() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .http(
                responseURL: URL(string: "https://dav.jianguoyun.com/dav/private-root/"),
                statusCode: 404
            )
        )

        _ = try await transport.list(path: nil, depth: 0)

        let request = try XCTUnwrap(OfflineURLProtocol.capturedRequests().only)
        XCTAssertNil(request.header(named: "Authorization"))
    }

    func testListBuildsDepthRequestAndMapsStrictMultiStatus() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .http(
                responseURL: URL(string: "https://dav.jianguoyun.com/dav/private-root/"),
                statusCode: 207,
                headers: ["Content-Type": "application/xml"],
                body: multiStatus(
                    responses: [
                        responseXML(
                            href: "/dav/private-root/",
                            isCollection: true,
                            etag: nil
                        ),
                        responseXML(
                            href:
                                "/dav/private-root/Caf%C3%A9%20%E7%A9%BA%E6%A0%BC%25/%E4%BA%8C.md",
                            isCollection: false,
                            etag: "&quot;v1&quot;"
                        ),
                    ]
                )
            )
        )

        let listing = try await transport.list(path: nil, depth: 1)

        XCTAssertEqual(
            listing,
            RemoteListing(
                statusCode: 207,
                entries: [
                    RemoteEntry(path: nil, isCollection: true, etagHeader: nil),
                    RemoteEntry(
                        path: try VerifierPath(decodedRelativePath: "Café 空格%/二.md"),
                        isCollection: false,
                        etagHeader: "\"v1\""
                    ),
                ]
            )
        )

        let request = try XCTUnwrap(OfflineURLProtocol.capturedRequests().only)
        XCTAssertEqual(request.url?.absoluteString, "https://dav.jianguoyun.com/dav/private-root/")
        XCTAssertEqual(request.method, "PROPFIND")
        XCTAssertEqual(request.header(named: "Depth"), "1")
        XCTAssertEqual(request.header(named: "Content-Type"), "application/xml; charset=utf-8")
        XCTAssertNil(request.header(named: "Authorization"))
        let body = try XCTUnwrap(request.body.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(body.contains("<d:resourcetype/>"))
        XCTAssertTrue(body.contains("<d:getetag/>"))
    }

    func testCollectionPutGetAndDeleteUseExactScopedTargets() async throws {
        let transport = try makeTransport()
        let directory = try VerifierPath(decodedRelativePath: "folder 空格%")
        let note = try VerifierPath(decodedRelativePath: "folder 空格%/note.md")
        let directoryURL =
            "https://dav.jianguoyun.com/dav/private-root/folder%20%E7%A9%BA%E6%A0%BC%25"
        let noteURL = directoryURL + "/note.md"

        OfflineURLProtocol.enqueue(
            .http(responseURL: URL(string: directoryURL), statusCode: 201),
            .http(responseURL: URL(string: noteURL), statusCode: 204),
            .http(
                responseURL: URL(string: noteURL),
                statusCode: 200,
                headers: ["ETag": "\"v2\""],
                body: Data("server-body".utf8)
            ),
            .http(responseURL: URL(string: noteURL), statusCode: 204)
        )

        let makeCollectionStatus = try await transport.makeCollection(path: directory)
        let putStatus = try await transport.put(
            path: note,
            body: Data("client-body".utf8),
            ifMatch: StrongETag(headerValue: "\"v1\"")
        )
        let read = try await transport.get(path: note)
        let deleteStatus = try await transport.delete(
            path: note,
            ifMatch: StrongETag(headerValue: "\"v2\"")
        )

        XCTAssertEqual(makeCollectionStatus, 201)
        XCTAssertEqual(putStatus, 204)
        XCTAssertEqual(
            read,
            RemoteRead(
                statusCode: 200,
                body: Data("server-body".utf8),
                etagHeader: "\"v2\""
            )
        )
        XCTAssertEqual(deleteStatus, 204)

        let requests = OfflineURLProtocol.capturedRequests()
        XCTAssertEqual(requests.map(\.method), ["MKCOL", "PUT", "GET", "DELETE"])
        XCTAssertEqual(
            requests.map { $0.url?.absoluteString }, [directoryURL, noteURL, noteURL, noteURL])
        XCTAssertEqual(requests.last?.header(named: "If-Match"), "\"v2\"")
        XCTAssertEqual(requests[1].body, Data("client-body".utf8))
        XCTAssertEqual(requests[1].header(named: "If-Match"), "\"v1\"")
        XCTAssertTrue(requests.allSatisfy { $0.header(named: "Authorization") == nil })
    }

    func testRejectsNonHTTPResponses() async throws {
        let transport = try makeTransport()
        let path = try VerifierPath(decodedRelativePath: "note.md")
        OfflineURLProtocol.enqueue(
            .nonHTTP(
                responseURL: URL(string: "https://dav.jianguoyun.com/dav/private-root/note.md")!,
                body: Data("not-http".utf8)
            )
        )

        await assertAsyncThrows {
            try await transport.get(path: path)
        }
    }

    func testRejectsEveryUnsafeOrDifferentFinalResponseURL() async throws {
        let transport = try makeTransport()
        let path = try VerifierPath(decodedRelativePath: "note.md")
        let forbiddenFinalURLs = [
            "http://dav.jianguoyun.com/dav/private-root/note.md",
            "https://evil.example/dav/private-root/note.md",
            "https://dav.jianguoyun.com:444/dav/private-root/note.md",
            "https://user:password@dav.jianguoyun.com/dav/private-root/note.md",
            "https://dav.jianguoyun.com/dav/private-root/note.md?leak=1",
            "https://dav.jianguoyun.com/dav/private-root/note.md#fragment",
            "https://dav.jianguoyun.com/dav/other/note.md",
            "https://dav.jianguoyun.com/private-root/note.md",
            "https://dav.jianguoyun.com/dav/private-root/other.md",
            "https://dav.jianguoyun.com/dav/private-root/note.md/",
        ]

        for finalURL in forbiddenFinalURLs {
            OfflineURLProtocol.enqueue(
                .http(responseURL: URL(string: finalURL), statusCode: 200)
            )
            await assertAsyncThrows(finalURL) {
                try await transport.get(path: path)
            }
        }
    }

    func testAcceptsExplicitDefaultHTTPSPortForSameFinalTarget() async throws {
        let transport = try makeTransport()
        let path = try VerifierPath(decodedRelativePath: "note.md")
        OfflineURLProtocol.enqueue(
            .http(
                responseURL: URL(
                    string: "https://dav.jianguoyun.com:443/dav/private-root/note.md"
                ),
                statusCode: 200,
                body: Data("ok".utf8)
            )
        )

        let read = try await transport.get(path: path)

        XCTAssertEqual(read.statusCode, 200)
        XCTAssertEqual(read.body, Data("ok".utf8))
    }

    func testInvalidDepthFailsBeforeCreatingAnyTask() async throws {
        let transport = try makeTransport()

        for depth in [-1, 2, Int.max] {
            await assertAsyncThrows("depth \(depth)") {
                try await transport.list(path: nil, depth: depth)
            }
        }

        XCTAssertTrue(OfflineURLProtocol.capturedRequests().isEmpty)
    }

    func testNonMultiStatusDoesNotParseErrorBody() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .http(
                responseURL: URL(string: "https://dav.jianguoyun.com/dav/private-root/"),
                statusCode: 404,
                body: Data("<not-even-closed".utf8)
            )
        )

        let listing = try await transport.list(path: nil, depth: 0)

        XCTAssertEqual(listing, RemoteListing(statusCode: 404, entries: []))
    }

    func testBareAuthenticated401IsClassifiedAsChallengeRejectionWithoutReadingBody() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .http(
                responseURL: URL(string: "https://dav.jianguoyun.com/dav/private-root/"),
                statusCode: 401,
                body: Data("sensitive-server-body".utf8)
            )
        )

        do {
            _ = try await transport.list(path: nil, depth: 0)
            XCTFail("expected challenge rejection classification")
        } catch let failure as VerifierFailure {
            XCTAssertEqual(failure, .authenticationChallengeRejected)
        } catch {
            XCTFail("unexpected error type")
        }
    }

    func testAcceptedChallengeThen401IsClassifiedAsCredentialRejection() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .authenticationChallenge(
                responseURL: URL(
                    string: "https://dav.jianguoyun.com/dav/private-root/"
                ),
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                previousFailureCount: 0,
                finalStatusCode: 401
            )
        )

        await assertVerifierFailure(.authenticationCredentialsRejected) {
            try await transport.list(path: nil, depth: 0)
        }
    }

    func testAcceptedChallengeCanCompleteWithSuccessfulResponse() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .authenticationChallenge(
                responseURL: URL(
                    string: "https://dav.jianguoyun.com/dav/private-root/"
                ),
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                previousFailureCount: 0,
                finalStatusCode: 207,
                finalBody: multiStatus(
                    responses: [
                        responseXML(
                            href: "/dav/private-root/",
                            isCollection: true,
                            etag: nil
                        )
                    ]
                )
            )
        )

        let listing = try await transport.list(path: nil, depth: 0)

        XCTAssertEqual(
            listing,
            RemoteListing(
                statusCode: 207,
                entries: [RemoteEntry(path: nil, isCollection: true, etagHeader: nil)]
            )
        )
    }

    func testCredentialEvidenceSurvivesRepeatedChallengeRejection() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .authenticationChallengeSequence(
                responseURL: URL(
                    string: "https://dav.jianguoyun.com/dav/private-root/"
                ),
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                finalStatusCode: 401
            )
        )

        await assertVerifierFailure(.authenticationCredentialsRejected) {
            try await transport.list(path: nil, depth: 0)
        }
    }

    func testAlreadyCancelledTaskDoesNotStartRequestOrHang() async throws {
        let transport = try makeTransport()
        let gate = AsyncGate()
        let request = Task {
            await gate.wait()
            return try await transport.list(path: nil, depth: 0)
        }
        request.cancel()
        await gate.open()

        let completion = expectation(description: "cancelled request completes")
        let result = Mutex<Bool?>(nil)
        let waiter = Task {
            let wasCancelled: Bool
            do {
                _ = try await request.value
                wasCancelled = false
            } catch is CancellationError {
                wasCancelled = true
            } catch let error as URLError where error.code == .cancelled {
                wasCancelled = true
            } catch {
                wasCancelled = false
            }
            result.withLock { $0 = wasCancelled }
            completion.fulfill()
        }

        await fulfillment(of: [completion], timeout: 1.0)
        waiter.cancel()

        XCTAssertEqual(result.withLock { $0 }, true)
        XCTAssertTrue(OfflineURLProtocol.capturedRequests().isEmpty)
    }

    func testRejectedChallengeThen401IsClassifiedAsChallengeRejection() async throws {
        let transport = try makeTransport()
        OfflineURLProtocol.enqueue(
            .authenticationChallenge(
                responseURL: URL(
                    string: "https://dav.jianguoyun.com/dav/private-root/"
                ),
                authenticationMethod: NSURLAuthenticationMethodNTLM,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                previousFailureCount: 0,
                finalStatusCode: 401
            )
        )

        await assertVerifierFailure(.authenticationChallengeRejected) {
            try await transport.list(path: nil, depth: 0)
        }
    }

    func testAuthenticationEvidenceDoesNotLeakBetweenRequests() async throws {
        let transport = try makeTransport()
        let rootURL = URL(string: "https://dav.jianguoyun.com/dav/private-root/")
        OfflineURLProtocol.enqueue(
            .authenticationChallenge(
                responseURL: rootURL,
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                previousFailureCount: 0,
                finalStatusCode: 404
            ),
            .http(responseURL: rootURL, statusCode: 401)
        )

        let first = try await transport.list(path: nil, depth: 0)
        XCTAssertEqual(first, RemoteListing(statusCode: 404, entries: []))

        await assertVerifierFailure(.authenticationChallengeRejected) {
            try await transport.list(path: nil, depth: 0)
        }
    }

    func testEveryAuthenticatedOperationUsesTheSame401Classification() async throws {
        let transport = try makeTransport()
        let path = try VerifierPath(decodedRelativePath: "note.md")
        let rootURL = URL(string: "https://dav.jianguoyun.com/dav/private-root/")
        let noteURL = URL(
            string: "https://dav.jianguoyun.com/dav/private-root/note.md"
        )
        OfflineURLProtocol.enqueue(
            .http(responseURL: rootURL, statusCode: 401),
            .http(responseURL: noteURL, statusCode: 401),
            .http(responseURL: noteURL, statusCode: 401),
            .http(responseURL: noteURL, statusCode: 401),
            .http(responseURL: noteURL, statusCode: 401)
        )

        await assertVerifierFailure(.authenticationChallengeRejected) {
            try await transport.list(path: nil, depth: 0)
        }
        await assertVerifierFailure(.authenticationChallengeRejected) {
            try await transport.makeCollection(path: path)
        }
        await assertVerifierFailure(.authenticationChallengeRejected) {
            try await transport.put(path: path, body: Data(), ifMatch: nil)
        }
        await assertVerifierFailure(.authenticationChallengeRejected) {
            try await transport.get(path: path)
        }
        await assertVerifierFailure(.authenticationChallengeRejected) {
            try await transport.delete(path: path, ifMatch: nil)
        }
    }

    func testResponseBodyAtHardLimitSucceeds() async throws {
        let transport = try makeTransport()
        let path = try VerifierPath(decodedRelativePath: "note.md")
        let halfLimit = URLSessionWebDAVTransport.maximumResponseBodyBytes / 2
        let firstChunk = Data(repeating: 0xA5, count: halfLimit)
        let secondChunk = Data(repeating: 0x5A, count: halfLimit)
        OfflineURLProtocol.enqueue(
            .streamingHTTP(
                responseURL: URL(
                    string: "https://dav.jianguoyun.com/dav/private-root/note.md"
                ),
                statusCode: 200,
                chunks: [firstChunk, secondChunk],
                finishes: true
            )
        )

        let read = try await transport.get(path: path)

        XCTAssertEqual(read.statusCode, 200)
        XCTAssertEqual(read.body.count, URLSessionWebDAVTransport.maximumResponseBodyBytes)
        XCTAssertEqual(read.body.first, 0xA5)
        XCTAssertEqual(read.body[halfLimit - 1], 0xA5)
        XCTAssertEqual(read.body[halfLimit], 0x5A)
        XCTAssertEqual(read.body.last, 0x5A)
    }

    func testResponseBodyOverHardLimitFailsAndCancelsLoading() async throws {
        let transport = try makeTransport()
        let path = try VerifierPath(decodedRelativePath: "note.md")
        OfflineURLProtocol.enqueue(
            .streamingHTTP(
                responseURL: URL(
                    string: "https://dav.jianguoyun.com/dav/private-root/note.md"
                ),
                statusCode: 200,
                chunks: [
                    Data(
                        repeating: 0xA5,
                        count: URLSessionWebDAVTransport.maximumResponseBodyBytes
                    ),
                    Data([0x5A]),
                ],
                finishes: false
            )
        )

        do {
            _ = try await transport.get(path: path)
            XCTFail("expected response body hard-limit failure")
        } catch let error as URLSessionWebDAVTransportError {
            XCTAssertEqual(error, .responseBodyTooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let cancellationObserved = await waitUntil {
            OfflineURLProtocol.stopLoadingCount() > 0
        }
        XCTAssertTrue(cancellationObserved, "expected URLSession task cancellation")
    }

    func testMultiStatusXMLAndEveryHrefFailClosed() async throws {
        let transport = try makeTransport()
        let safe = responseXML(href: "/dav/private-root/safe.md", isCollection: false, etag: nil)
        let unsafe = responseXML(
            href: "https://evil.example/dav/private-root/evil.md", isCollection: false, etag: nil)
        let outsideRoot = responseXML(href: "/dav/other/evil.md", isCollection: false, etag: nil)
        let query = responseXML(
            href: "/dav/private-root/safe.md?secret=1", isCollection: false, etag: nil)
        let documents: [(name: String, body: Data)] = [
            ("empty document", Data()),
            (
                "truncated document",
                Data("<d:multistatus xmlns:d=\"DAV:\"><d:response>".utf8)
            ),
            ("absolute href outside endpoint", multiStatus(responses: [unsafe])),
            ("href outside dedicated root", multiStatus(responses: [outsideRoot])),
            ("href with query", multiStatus(responses: [query])),
            ("mixed safe and unsafe hrefs", multiStatus(responses: [safe, unsafe])),
        ]

        for document in documents {
            OfflineURLProtocol.enqueue(
                .http(
                    responseURL: URL(string: "https://dav.jianguoyun.com/dav/private-root/"),
                    statusCode: 207,
                    body: document.body
                )
            )
            await assertAsyncThrows(document.name) {
                try await transport.list(path: nil, depth: 1)
            }
        }
    }

    func testEphemeralConfigurationDisablesCredentialCookieAndURLCaches() {
        let first = URLSessionWebDAVTransport.makeEphemeralConfiguration(
            protocolClasses: [OfflineURLProtocol.self]
        )
        let second = URLSessionWebDAVTransport.makeEphemeralConfiguration(
            protocolClasses: [OfflineURLProtocol.self]
        )

        XCTAssertFalse(first === second)
        XCTAssertNil(first.urlCredentialStorage)
        XCTAssertNil(first.httpCookieStorage)
        XCTAssertFalse(first.httpShouldSetCookies)
        XCTAssertEqual(first.httpCookieAcceptPolicy, .never)
        XCTAssertNil(first.urlCache)
        XCTAssertEqual(first.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(
            first.timeoutIntervalForRequest,
            URLSessionWebDAVTransport.requestTimeout
        )
        XCTAssertEqual(
            first.timeoutIntervalForResource,
            URLSessionWebDAVTransport.resourceTimeout
        )
        XCTAssertEqual(
            first.protocolClasses?.map(ObjectIdentifier.init),
            [ObjectIdentifier(OfflineURLProtocol.self)])
    }

    func testChallengeResolutionUsesExistingStrictPolicyAndNonPersistentCredential() throws {
        let credentials = Credentials(
            username: "user@example.com", applicationPassword: "app-password")
        let authenticated = WebDAVSessionDelegate(credentials: credentials)
        let unauthenticated = WebDAVSessionDelegate(credentials: nil)

        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest] {
            let challenge = makeChallenge(authenticationMethod: method)
            let resolution = authenticated.resolve(challenge: challenge)

            XCTAssertEqual(resolution.disposition, .useCredential)
            XCTAssertEqual(resolution.authenticationEvidence, .credentialOffered)
            XCTAssertEqual(resolution.credential?.user, credentials.username)
            XCTAssertEqual(resolution.credential?.password, credentials.applicationPassword)
            XCTAssertEqual(
                resolution.credential?.persistence,
                URLCredential.Persistence.none
            )

            let unauthenticatedResolution = unauthenticated.resolve(challenge: challenge)
            XCTAssertEqual(unauthenticatedResolution.disposition, .rejectProtectionSpace)
            XCTAssertEqual(
                unauthenticatedResolution.authenticationEvidence,
                .challengeRejected
            )
        }

        let serverTrustResolution = authenticated.resolve(
            challenge: makeChallenge(
                authenticationMethod: NSURLAuthenticationMethodServerTrust
            )
        )
        XCTAssertEqual(serverTrustResolution.disposition, .performDefaultHandling)
        XCTAssertEqual(serverTrustResolution.authenticationEvidence, .notObserved)

        let rejected = [
            makeChallenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic, host: "evil.example"),
            makeChallenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPDigest, protocolName: "http",
                port: 80),
            makeChallenge(authenticationMethod: NSURLAuthenticationMethodHTTPBasic, port: 444),
            makeChallenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic, previousFailureCount: 1),
            makeChallenge(authenticationMethod: NSURLAuthenticationMethodNTLM),
        ]
        for challenge in rejected {
            let resolution = authenticated.resolve(challenge: challenge)
            XCTAssertEqual(resolution.disposition, .rejectProtectionSpace)
            XCTAssertNil(resolution.credential)
            XCTAssertEqual(resolution.authenticationEvidence, .challengeRejected)
        }
    }

    func testSessionLevelChallengeNeverReceivesAccountCredential() throws {
        let delegate = WebDAVSessionDelegate(
            credentials: Credentials(
                username: "user@example.com",
                applicationPassword: "app-password"
            )
        )
        let configuration = URLSessionWebDAVTransport.makeEphemeralConfiguration(
            protocolClasses: [OfflineURLProtocol.self]
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        let basicCapture = AuthenticationChallengeCapture()
        delegate.urlSession(
            session,
            didReceive: makeChallenge(
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic
            )
        ) { disposition, credential in
            basicCapture.store(disposition: disposition, credential: credential)
        }

        let basicResult = basicCapture.value()
        XCTAssertEqual(basicResult.disposition, .rejectProtectionSpace)
        XCTAssertNil(basicResult.credential)

        let trustCapture = AuthenticationChallengeCapture()
        delegate.urlSession(
            session,
            didReceive: makeChallenge(
                authenticationMethod: NSURLAuthenticationMethodServerTrust
            )
        ) { disposition, credential in
            trustCapture.store(disposition: disposition, credential: credential)
        }

        let trustResult = trustCapture.value()
        XCTAssertEqual(trustResult.disposition, .performDefaultHandling)
        XCTAssertNil(trustResult.credential)
    }

    func testDelegateUnconditionallyRejectsRedirect() throws {
        let delegate = WebDAVSessionDelegate(
            credentials: Credentials(username: "user", applicationPassword: "password")
        )
        let configuration = URLSessionWebDAVTransport.makeEphemeralConfiguration(
            protocolClasses: [OfflineURLProtocol.self]
        )
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://dav.jianguoyun.com/dav/private-root/note.md")!
        let task = session.dataTask(with: original)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        let proposed = URLRequest(
            url: URL(string: "https://dav.jianguoyun.com/dav/private-root/other.md")!
        )
        let capture = RedirectCapture()

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: proposed
        ) { request in
            capture.store(request)
        }

        let result = capture.value()
        XCTAssertTrue(result.called)
        XCTAssertNil(result.url)
    }

    private func makeTransport() throws -> URLSessionWebDAVTransport {
        URLSessionWebDAVTransport(
            dedicatedRoot: try VerifierPath(decodedRelativePath: "private-root"),
            credentials: Credentials(
                username: "user@example.com",
                applicationPassword: "application-password"
            ),
            protocolClasses: [OfflineURLProtocol.self]
        )
    }

    private func makeChallenge(
        authenticationMethod: String,
        host: String = "dav.jianguoyun.com",
        protocolName: String = "https",
        port: Int = 443,
        previousFailureCount: Int = 0
    ) -> URLAuthenticationChallenge {
        let protectionSpace = URLProtectionSpace(
            host: host,
            port: port,
            protocol: protocolName,
            realm: nil,
            authenticationMethod: authenticationMethod
        )
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )
    }
}

private struct CapturedRequest: Sendable {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let body: Data?

    init(_ request: URLRequest) {
        url = request.url
        method = request.httpMethod
        headers = request.allHTTPHeaderFields ?? [:]
        body = Self.readBody(from: request)
    }

    func header(named name: String) -> String? {
        headers.first { key, _ in
            key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let capacity = 16 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var body = Data()
        while true {
            let count = stream.read(buffer, maxLength: capacity)
            if count > 0 {
                body.append(buffer, count: count)
                continue
            }
            return count == 0 ? body : nil
        }
    }
}

private enum OfflineResponse: Sendable {
    case http(
        responseURL: URL?,
        statusCode: Int,
        headers: [String: String] = [:],
        body: Data = Data()
    )
    case streamingHTTP(
        responseURL: URL?,
        statusCode: Int,
        headers: [String: String] = [:],
        chunks: [Data],
        finishes: Bool
    )
    case nonHTTP(responseURL: URL, body: Data)
    case authenticationChallenge(
        responseURL: URL?,
        authenticationMethod: String,
        host: String,
        protocolName: String,
        port: Int,
        previousFailureCount: Int,
        finalStatusCode: Int,
        finalBody: Data = Data()
    )
    case authenticationChallengeSequence(
        responseURL: URL?,
        authenticationMethod: String,
        host: String,
        protocolName: String,
        port: Int,
        finalStatusCode: Int
    )
}

private final class OfflineURLProtocol: URLProtocol, URLAuthenticationChallengeSender,
    @unchecked Sendable
{
    private struct State: Sendable {
        var responses: [OfflineResponse] = []
        var requests: [CapturedRequest] = []
        var stopLoadingCount = 0
    }

    private static let state = Mutex(State())
    private let stopped = Mutex(false)
    private struct ChallengeState: Sendable {
        let responseURL: URL?
        let authenticationMethod: String
        let host: String
        let protocolName: String
        let port: Int
        let finalStatusCode: Int
        let finalBody: Data
        var sendsRepeatedChallenge: Bool
    }

    private let challengeState = Mutex<ChallengeState?>(nil)
    private let deliveryQueue = DispatchQueue(label: "OfflineURLProtocol.delivery")

    static func reset() {
        state.withLock { value in
            value = State()
        }
    }

    static func enqueue(_ responses: OfflineResponse...) {
        state.withLock { value in
            value.responses.append(contentsOf: responses)
        }
    }

    static func capturedRequests() -> [CapturedRequest] {
        state.withLock { $0.requests }
    }

    static func stopLoadingCount() -> Int {
        state.withLock { $0.stopLoadingCount }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = Self.state.withLock { value -> OfflineResponse? in
            value.requests.append(CapturedRequest(request))
            guard !value.responses.isEmpty else {
                return nil
            }
            return value.responses.removeFirst()
        }

        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch response {
        case .http(let responseURL, let statusCode, let headers, let body):
            guard
                let httpResponse = makeHTTPResponse(
                    responseURL: responseURL,
                    statusCode: statusCode,
                    headers: headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)

        case .streamingHTTP(let responseURL, let statusCode, let headers, let chunks, let finishes):
            guard
                let httpResponse = makeHTTPResponse(
                    responseURL: responseURL,
                    statusCode: statusCode,
                    headers: headers
                )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            deliveryQueue.async { [self] in
                guard !isStopped else {
                    return
                }
                client?.urlProtocol(
                    self,
                    didReceive: httpResponse,
                    cacheStoragePolicy: .notAllowed
                )
                for chunk in chunks {
                    guard !isStopped else {
                        return
                    }
                    if !chunk.isEmpty {
                        client?.urlProtocol(self, didLoad: chunk)
                    }
                }
                guard finishes, !isStopped else {
                    return
                }
                client?.urlProtocolDidFinishLoading(self)
            }

        case .nonHTTP(let responseURL, let body):
            let response = URLResponse(
                url: responseURL,
                mimeType: "application/octet-stream",
                expectedContentLength: body.count,
                textEncodingName: nil
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)

        case .authenticationChallenge(
            let responseURL,
            let authenticationMethod,
            let host,
            let protocolName,
            let port,
            let previousFailureCount,
            let finalStatusCode,
            let finalBody
        ):
            challengeState.withLock { value in
                value = ChallengeState(
                    responseURL: responseURL,
                    authenticationMethod: authenticationMethod,
                    host: host,
                    protocolName: protocolName,
                    port: port,
                    finalStatusCode: finalStatusCode,
                    finalBody: finalBody,
                    sendsRepeatedChallenge: false
                )
            }
            sendAuthenticationChallenge(
                authenticationMethod: authenticationMethod,
                host: host,
                protocolName: protocolName,
                port: port,
                previousFailureCount: previousFailureCount
            )

        case .authenticationChallengeSequence(
            let responseURL,
            let authenticationMethod,
            let host,
            let protocolName,
            let port,
            let finalStatusCode
        ):
            challengeState.withLock { value in
                value = ChallengeState(
                    responseURL: responseURL,
                    authenticationMethod: authenticationMethod,
                    host: host,
                    protocolName: protocolName,
                    port: port,
                    finalStatusCode: finalStatusCode,
                    finalBody: Data(),
                    sendsRepeatedChallenge: true
                )
            }
            sendAuthenticationChallenge(
                authenticationMethod: authenticationMethod,
                host: host,
                protocolName: protocolName,
                port: port,
                previousFailureCount: 0
            )
        }
    }

    func use(_: URLCredential, for _: URLAuthenticationChallenge) {
        let repeatedChallenge = challengeState.withLock { value -> ChallengeState? in
            guard var current = value, current.sendsRepeatedChallenge else {
                return nil
            }
            current.sendsRepeatedChallenge = false
            value = current
            return current
        }
        guard let repeatedChallenge else {
            finishAuthenticationChallenge()
            return
        }
        sendAuthenticationChallenge(
            authenticationMethod: repeatedChallenge.authenticationMethod,
            host: repeatedChallenge.host,
            protocolName: repeatedChallenge.protocolName,
            port: repeatedChallenge.port,
            previousFailureCount: 1
        )
    }

    func continueWithoutCredential(for _: URLAuthenticationChallenge) {
        finishAuthenticationChallenge()
    }

    func cancel(_: URLAuthenticationChallenge) {
        finishAuthenticationChallenge()
    }

    func performDefaultHandling(for _: URLAuthenticationChallenge) {
        finishAuthenticationChallenge()
    }

    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {
        finishAuthenticationChallenge()
    }

    override func stopLoading() {
        let firstStop = stopped.withLock { value in
            guard !value else {
                return false
            }
            value = true
            return true
        }
        guard firstStop else {
            return
        }
        Self.state.withLock { $0.stopLoadingCount += 1 }
    }

    private var isStopped: Bool {
        stopped.withLock { $0 }
    }

    private func finishAuthenticationChallenge() {
        guard
            let challenge = challengeState.withLock({ value in
                defer { value = nil }
                return value
            }),
            let response = makeHTTPResponse(
                responseURL: challenge.responseURL,
                statusCode: challenge.finalStatusCode,
                headers: [:]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !challenge.finalBody.isEmpty {
            client?.urlProtocol(self, didLoad: challenge.finalBody)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func sendAuthenticationChallenge(
        authenticationMethod: String,
        host: String,
        protocolName: String,
        port: Int,
        previousFailureCount: Int
    ) {
        let protectionSpace = URLProtectionSpace(
            host: host,
            port: port,
            protocol: protocolName,
            realm: "offline-test",
            authenticationMethod: authenticationMethod
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: self
        )
        client?.urlProtocol(self, didReceive: challenge)
    }

    private func makeHTTPResponse(
        responseURL: URL?,
        statusCode: Int,
        headers: [String: String]
    ) -> HTTPURLResponse? {
        guard let url = responseURL ?? request.url else {
            return nil
        }
        return HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender, @unchecked Sendable
{
    func use(_: URLCredential, for _: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for _: URLAuthenticationChallenge) {}
    func cancel(_: URLAuthenticationChallenge) {}
    func performDefaultHandling(for _: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with _: URLAuthenticationChallenge) {}
}

private final class RedirectCapture: @unchecked Sendable {
    private struct Value: Sendable {
        var called = false
        var url: URL?
    }

    private let storage = Mutex(Value())

    func store(_ request: URLRequest?) {
        storage.withLock { value in
            value.called = true
            value.url = request?.url
        }
    }

    func value() -> (called: Bool, url: URL?) {
        storage.withLock { value in
            (value.called, value.url)
        }
    }
}

private final class AuthenticationChallengeCapture: @unchecked Sendable {
    private struct Value: @unchecked Sendable {
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?
    }

    private let storage = Mutex(Value())

    func store(
        disposition: URLSession.AuthChallengeDisposition,
        credential: URLCredential?
    ) {
        storage.withLock { value in
            value.disposition = disposition
            value.credential = credential
        }
    }

    func value() -> (
        disposition: URLSession.AuthChallengeDisposition?,
        credential: URLCredential?
    ) {
        storage.withLock { value in
            (value.disposition, value.credential)
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

extension Array {
    fileprivate var only: Element? {
        count == 1 ? self[0] : nil
    }
}

private func multiStatus(responses: [String]) -> Data {
    Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:">
        \(responses.joined(separator: "\n"))
        </d:multistatus>
        """.utf8
    )
}

private func responseXML(href: String, isCollection: Bool, etag: String?) -> String {
    let resourceType =
        isCollection
        ? "<d:resourcetype><d:collection/></d:resourcetype>"
        : "<d:resourcetype/>"
    let etagXML = etag.map { "<d:getetag>\($0)</d:getetag>" } ?? ""
    return """
          <d:response>
            <d:href>\(href)</d:href>
            <d:propstat>
              <d:prop>\(resourceType)\(etagXML)</d:prop>
              <d:status>HTTP/1.1 200 OK</d:status>
            </d:propstat>
          </d:response>
        """
}

private func assertAsyncThrows<T>(
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected failure \(message)", file: file, line: line)
    } catch {}
}

private func assertVerifierFailure<T>(
    _ expected: VerifierFailure,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: () async throws -> T
) async {
    do {
        _ = try await operation()
        XCTFail("expected verifier failure \(expected)", file: file, line: line)
    } catch let failure as VerifierFailure {
        XCTAssertEqual(failure, expected, file: file, line: line)
    } catch {
        XCTFail("unexpected error: \(error)", file: file, line: line)
    }
}

private func waitUntil(
    attempts: Int = 100,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if condition() {
            return true
        }
        try? await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}
