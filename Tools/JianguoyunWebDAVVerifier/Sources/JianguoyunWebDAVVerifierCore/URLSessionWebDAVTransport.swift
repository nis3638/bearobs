import Foundation
import Synchronization

public final class URLSessionWebDAVTransport: VerifierRemote, @unchecked Sendable {
    static let maximumResponseBodyBytes = 4 * 1024 * 1024
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 120

    private static let propfindBody = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/></d:prop></d:propfind>
        """.utf8
    )

    private struct SessionClient {
        let session: URLSession
        let delegate: WebDAVSessionDelegate
        let isAuthenticated: Bool
    }

    private let scope: RemoteScope
    private let authenticatedClient: SessionClient
    private let unauthenticatedClient: SessionClient

    public convenience init(
        dedicatedRoot: VerifierPath,
        credentials: Credentials
    ) {
        self.init(
            dedicatedRoot: dedicatedRoot,
            credentials: credentials,
            injectedProtocolClasses: nil
        )
    }

    convenience init(
        dedicatedRoot: VerifierPath,
        credentials: Credentials,
        protocolClasses: [AnyClass]
    ) {
        self.init(
            dedicatedRoot: dedicatedRoot,
            credentials: credentials,
            injectedProtocolClasses: protocolClasses
        )
    }

    private init(
        dedicatedRoot: VerifierPath,
        credentials: Credentials,
        injectedProtocolClasses: [AnyClass]?
    ) {
        scope = RemoteScope(dedicatedRoot: dedicatedRoot)

        let authenticatedDelegate = WebDAVSessionDelegate(credentials: credentials)
        authenticatedClient = SessionClient(
            session: URLSession(
                configuration: Self.makeEphemeralConfiguration(
                    injectedProtocolClasses: injectedProtocolClasses
                ),
                delegate: authenticatedDelegate,
                delegateQueue: nil
            ),
            delegate: authenticatedDelegate,
            isAuthenticated: true
        )

        let unauthenticatedDelegate = WebDAVSessionDelegate(credentials: nil)
        unauthenticatedClient = SessionClient(
            session: URLSession(
                configuration: Self.makeEphemeralConfiguration(
                    injectedProtocolClasses: injectedProtocolClasses
                ),
                delegate: unauthenticatedDelegate,
                delegateQueue: nil
            ),
            delegate: unauthenticatedDelegate,
            isAuthenticated: false
        )
    }

    public func unauthenticatedDepthZeroStatus() async throws -> Int {
        var request = URLRequest(url: scope.rootURL)
        request.httpMethod = "PROPFIND"
        request.setValue("0", forHTTPHeaderField: "Depth")

        let (_, response) = try await execute(
            request,
            expectedPath: nil,
            using: unauthenticatedClient
        )
        return response.statusCode
    }

    public func list(path: VerifierPath?, depth: Int) async throws -> RemoteListing {
        guard depth == 0 || depth == 1 else {
            throw URLSessionWebDAVTransportError.invalidDepth
        }

        let targetURL = try resourceURL(for: path)
        var request = URLRequest(url: targetURL)
        request.httpMethod = "PROPFIND"
        request.setValue(String(depth), forHTTPHeaderField: "Depth")
        request.setValue(
            "application/xml; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.propfindBody

        let (data, response) = try await execute(
            request,
            expectedPath: path,
            using: authenticatedClient
        )
        guard response.statusCode == 207 else {
            return RemoteListing(statusCode: response.statusCode, entries: [])
        }

        let multiStatus = try DAVMultiStatusParser().parse(data)
        let entries = try multiStatus.entries.map { entry in
            RemoteEntry(
                path: try scope.relativePath(forHref: entry.href),
                isCollection: entry.isCollection,
                etagHeader: entry.etagHeader
            )
        }
        return RemoteListing(statusCode: response.statusCode, entries: entries)
    }

    public func makeCollection(path: VerifierPath) async throws -> Int {
        var request = URLRequest(url: try scope.resourceURL(for: path))
        request.httpMethod = "MKCOL"

        let (_, response) = try await execute(
            request,
            expectedPath: path,
            using: authenticatedClient
        )
        return response.statusCode
    }

    public func put(
        path: VerifierPath,
        body: Data,
        ifMatch: StrongETag?
    ) async throws -> Int {
        var request = URLRequest(url: try scope.resourceURL(for: path))
        request.httpMethod = "PUT"
        request.httpBody = body
        if let ifMatch {
            request.setValue(ifMatch.headerValue, forHTTPHeaderField: "If-Match")
        }

        let (_, response) = try await execute(
            request,
            expectedPath: path,
            using: authenticatedClient
        )
        return response.statusCode
    }

    public func get(path: VerifierPath) async throws -> RemoteRead {
        var request = URLRequest(url: try scope.resourceURL(for: path))
        request.httpMethod = "GET"

        let (data, response) = try await execute(
            request,
            expectedPath: path,
            using: authenticatedClient
        )
        return RemoteRead(
            statusCode: response.statusCode,
            body: data,
            etagHeader: response.value(forHTTPHeaderField: "ETag")
        )
    }

    public func delete(path: VerifierPath, ifMatch: StrongETag?) async throws -> Int {
        var request = URLRequest(url: try scope.resourceURL(for: path))
        request.httpMethod = "DELETE"
        if let ifMatch {
            request.setValue(ifMatch.headerValue, forHTTPHeaderField: "If-Match")
        }

        let (_, response) = try await execute(
            request,
            expectedPath: path,
            using: authenticatedClient
        )
        return response.statusCode
    }

    static func makeEphemeralConfiguration(
        protocolClasses: [AnyClass]
    ) -> URLSessionConfiguration {
        makeEphemeralConfiguration(injectedProtocolClasses: protocolClasses)
    }

    private static func makeEphemeralConfiguration(
        injectedProtocolClasses: [AnyClass]?
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        if let injectedProtocolClasses {
            configuration.protocolClasses = injectedProtocolClasses
        }
        return configuration
    }

    private func resourceURL(for path: VerifierPath?) throws -> URL {
        guard let path else {
            return scope.rootURL
        }
        return try scope.resourceURL(for: path)
    }

    private func execute(
        _ request: URLRequest,
        expectedPath: VerifierPath?,
        using client: SessionClient
    ) async throws -> (Data, HTTPURLResponse) {
        guard let expectedURL = request.url else {
            throw URLSessionWebDAVTransportError.invalidRequestURL
        }

        let result: WebDAVTaskResult
        do {
            result = try await client.delegate.data(for: request, using: client.session)
        } catch let failure as WebDAVSessionTaskFailure {
            if client.isAuthenticated,
                Self.isAuthenticationFailure(failure.underlying)
            {
                throw Self.authenticationFailure(for: failure.authenticationEvidence)
            }
            throw failure.underlying
        }

        guard let httpResponse = result.response as? HTTPURLResponse else {
            throw URLSessionWebDAVTransportError.nonHTTPResponse
        }
        try validateFinalResponseURL(
            httpResponse.url,
            expectedURL: expectedURL,
            expectedPath: expectedPath
        )
        if client.isAuthenticated, httpResponse.statusCode == 401 {
            throw Self.authenticationFailure(for: result.authenticationEvidence)
        }
        return (result.data, httpResponse)
    }

    private static func authenticationFailure(
        for evidence: WebDAVAuthenticationEvidence
    ) -> VerifierFailure {
        switch evidence {
        case .credentialOffered:
            .authenticationCredentialsRejected
        case .notObserved, .challengeRejected:
            .authenticationChallengeRejected
        }
    }

    private static func isAuthenticationFailure(_ error: any Error) -> Bool {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else {
            return false
        }
        return error.code == URLError.Code.userAuthenticationRequired.rawValue
            || error.code == URLError.Code.userCancelledAuthentication.rawValue
    }

    private func validateFinalResponseURL(
        _ finalURL: URL?,
        expectedURL: URL,
        expectedPath: VerifierPath?
    ) throws {
        guard let finalURL,
            let finalComponents = URLComponents(
                url: finalURL,
                resolvingAgainstBaseURL: false
            ),
            let expectedComponents = URLComponents(
                url: expectedURL,
                resolvingAgainstBaseURL: false
            ),
            let scheme = finalComponents.scheme,
            scheme.caseInsensitiveCompare(JianguoyunEndpoint.scheme) == .orderedSame,
            let host = finalComponents.host,
            host.caseInsensitiveCompare(JianguoyunEndpoint.host) == .orderedSame,
            finalComponents.port == nil || finalComponents.port == JianguoyunEndpoint.port,
            finalComponents.user == nil,
            finalComponents.password == nil,
            finalComponents.percentEncodedQuery == nil,
            finalComponents.percentEncodedFragment == nil,
            finalComponents.percentEncodedPath == expectedComponents.percentEncodedPath
        else {
            throw URLSessionWebDAVTransportError.unsafeFinalResponseURL
        }

        let scopedPath: VerifierPath?
        do {
            scopedPath = try scope.relativePath(forHref: finalURL.absoluteString)
        } catch {
            throw URLSessionWebDAVTransportError.unsafeFinalResponseURL
        }
        guard scopedPath == expectedPath else {
            throw URLSessionWebDAVTransportError.unsafeFinalResponseURL
        }
    }
}

enum URLSessionWebDAVTransportError: Error, Equatable, Sendable {
    case invalidDepth
    case invalidRequestURL
    case nonHTTPResponse
    case responseBodyTooLarge
    case unsafeFinalResponseURL
}

struct WebDAVChallengeResolution {
    let disposition: URLSession.AuthChallengeDisposition
    let credential: URLCredential?
    let authenticationEvidence: WebDAVAuthenticationEvidence
}

enum WebDAVAuthenticationEvidence: Equatable, Sendable {
    case notObserved
    case challengeRejected
    case credentialOffered

    func merging(_ other: Self) -> Self {
        switch (self, other) {
        case (.credentialOffered, _), (_, .credentialOffered):
            .credentialOffered
        case (.challengeRejected, _), (_, .challengeRejected):
            .challengeRejected
        case (.notObserved, .notObserved):
            .notObserved
        }
    }
}

struct WebDAVTaskResult {
    let data: Data
    let response: URLResponse
    let authenticationEvidence: WebDAVAuthenticationEvidence
}

private struct WebDAVSessionTaskFailure: Error {
    let underlying: any Error
    let authenticationEvidence: WebDAVAuthenticationEvidence
}

private final class WebDAVTaskStartGate: @unchecked Sendable {
    private enum State: Sendable {
        case waiting
        case started
        case cancelled
    }

    private let state = Mutex(State.waiting)

    func start(_ operation: () -> Void) -> Bool {
        state.withLock { state in
            guard case .waiting = state else {
                return false
            }
            operation()
            state = .started
            return true
        }
    }

    func cancel() -> Bool {
        state.withLock { state in
            switch state {
            case .waiting:
                state = .cancelled
                return false
            case .started:
                state = .cancelled
                return true
            case .cancelled:
                return false
            }
        }
    }
}

final class WebDAVSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct PendingTask {
        let continuation: CheckedContinuation<WebDAVTaskResult, any Error>
        var response: URLResponse?
        var body = Data()
        var authenticationEvidence = WebDAVAuthenticationEvidence.notObserved
    }

    private let credentials: Credentials?
    private let challengePolicy = ChallengePolicy()
    private let maximumResponseBodyBytes: Int
    private let pendingTasks = Mutex<[Int: PendingTask]>([:])

    init(
        credentials: Credentials?,
        maximumResponseBodyBytes: Int = URLSessionWebDAVTransport.maximumResponseBodyBytes
    ) {
        self.credentials = credentials
        self.maximumResponseBodyBytes = maximumResponseBodyBytes
    }

    func data(
        for request: URLRequest,
        using session: URLSession
    ) async throws -> WebDAVTaskResult {
        let task = session.dataTask(with: request)
        let startGate = WebDAVTaskStartGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let started = startGate.start {
                    pendingTasks.withLock { tasks in
                        tasks[task.taskIdentifier] = PendingTask(continuation: continuation)
                    }
                    task.resume()
                }
                if !started {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            if startGate.cancel() {
                task.cancel()
            }
        }
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let isPending = pendingTasks.withLock { tasks in
            guard var pending = tasks[dataTask.taskIdentifier] else {
                return false
            }
            pending.response = response
            tasks[dataTask.taskIdentifier] = pending
            return true
        }
        completionHandler(isPending ? .allow : .cancel)
    }

    func urlSession(
        _: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let overflowContinuation = pendingTasks.withLock {
            tasks
                -> CheckedContinuation<WebDAVTaskResult, any Error>? in
            guard var pending = tasks[dataTask.taskIdentifier] else {
                return nil
            }

            if (pending.response as? HTTPURLResponse)?.statusCode == 401 {
                return nil
            }

            guard data.count <= maximumResponseBodyBytes - pending.body.count else {
                tasks.removeValue(forKey: dataTask.taskIdentifier)
                return pending.continuation
            }

            pending.body.append(data)
            tasks[dataTask.taskIdentifier] = pending
            return nil
        }

        guard let overflowContinuation else {
            return
        }
        dataTask.cancel()
        overflowContinuation.resume(
            throwing: URLSessionWebDAVTransportError.responseBodyTooLarge
        )
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard
            let pending = pendingTasks.withLock({ tasks in
                tasks.removeValue(forKey: task.taskIdentifier)
            })
        else {
            return
        }

        if let error {
            pending.continuation.resume(
                throwing: WebDAVSessionTaskFailure(
                    underlying: error,
                    authenticationEvidence: pending.authenticationEvidence
                )
            )
            return
        }
        guard let response = pending.response else {
            pending.continuation.resume(throwing: URLError(.badServerResponse))
            return
        }
        pending.continuation.resume(
            returning: WebDAVTaskResult(
                data: pending.body,
                response: response,
                authenticationEvidence: pending.authenticationEvidence
            )
        )
    }

    func resolve(challenge: URLAuthenticationChallenge) -> WebDAVChallengeResolution {
        let protectionSpace = challenge.protectionSpace
        let context = ChallengeContext(
            method: Self.authenticationMethod(protectionSpace.authenticationMethod),
            host: protectionSpace.host,
            protocolName: protectionSpace.protocol ?? "",
            port: protectionSpace.port,
            previousFailureCount: challenge.previousFailureCount
        )

        switch challengePolicy.disposition(
            for: context,
            credentialsAvailable: credentials != nil
        ) {
        case .performDefaultHandling:
            return WebDAVChallengeResolution(
                disposition: .performDefaultHandling,
                credential: nil,
                authenticationEvidence: .notObserved
            )

        case .useCredential:
            guard let credentials else {
                return WebDAVChallengeResolution(
                    disposition: .rejectProtectionSpace,
                    credential: nil,
                    authenticationEvidence: .challengeRejected
                )
            }
            return WebDAVChallengeResolution(
                disposition: .useCredential,
                credential: URLCredential(
                    user: credentials.username,
                    password: credentials.applicationPassword,
                    persistence: .none
                ),
                authenticationEvidence: .credentialOffered
            )

        case .reject:
            return WebDAVChallengeResolution(
                disposition: .rejectProtectionSpace,
                credential: nil,
                authenticationEvidence: .challengeRejected
            )
        }
    }

    func urlSession(
        _: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
    ) {
        guard
            Self.authenticationMethod(challenge.protectionSpace.authenticationMethod)
                == .serverTrust
        else {
            completionHandler(.rejectProtectionSpace, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler:
            @escaping @Sendable (
                URLSession.AuthChallengeDisposition,
                URLCredential?
            ) -> Void
    ) {
        let resolution = resolve(challenge: challenge)
        pendingTasks.withLock { tasks in
            guard var pending = tasks[task.taskIdentifier] else {
                return
            }
            pending.authenticationEvidence = pending.authenticationEvidence.merging(
                resolution.authenticationEvidence
            )
            tasks[task.taskIdentifier] = pending
        }
        completionHandler(resolution.disposition, resolution.credential)
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private static func authenticationMethod(_ value: String) -> AuthenticationMethod {
        switch value {
        case NSURLAuthenticationMethodHTTPBasic:
            .basic
        case NSURLAuthenticationMethodHTTPDigest:
            .digest
        case NSURLAuthenticationMethodServerTrust:
            .serverTrust
        default:
            .other
        }
    }
}
