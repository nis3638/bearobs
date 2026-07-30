import Foundation

final class ControlledWebDAVFixture: @unchecked Sendable {
    enum Fault: Sendable {
        case httpStatus(Int, headers: [String: String])
        case interrupted(afterByteCount: Int, code: URLError.Code)
        case urlError(URLError.Code)
    }

    struct Diagnostic: CustomStringConvertible, Sendable {
        let method: String
        let percentEncodedPath: String
        let bodyByteCount: Int
        let statusCode: Int?
        let errorCode: Int?

        var description: String {
            let outcome =
                statusCode.map { "status=\($0)" }
                ?? errorCode.map { "urlError=\($0)" }
                ?? "outcome=unknown"
            return "\(method) \(percentEncodedPath) bodyBytes=\(bodyByteCount) \(outcome)"
        }
    }

    let root: URL
    let baseURL: URL

    private let contract: WebDAVFixtureContract
    private let propfindBody: Data
    private let lock = NSLock()
    private var state: State

    init(root: URL) throws {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let data = try Self.readFixtureFile("contract.json", below: root)
        let contract = try JSONDecoder().decode(WebDAVFixtureContract.self, from: data)
        guard
            contract.schemaVersion == 1,
            contract.fixture.milestone == "M0-06",
            contract.fixture.synthetic,
            !contract.fixture.containsRealUserContent
        else {
            throw FixtureError.invalidContract
        }

        var resources: [String: ResourceState] = [:]
        for resource in contract.resources {
            let body =
                try resource.body.map {
                    try Self.readFixtureFile($0, below: root)
                } ?? Data()
            resources[resource.percentEncodedPath] = ResourceState(
                id: resource.id,
                kind: resource.kind,
                body: body,
                etag: resource.etag,
                lastModified: resource.lastModified,
                revision: 1
            )
        }

        let host = "\(UUID().uuidString.lowercased()).webdav.fixture.invalid"
        guard let baseURL = URL(string: "https://\(host)") else {
            throw FixtureError.invalidBaseURL
        }

        self.root = root
        self.baseURL = baseURL
        self.contract = contract
        propfindBody = try Self.readFixtureFile(contract.propfind.body, below: root)
        state = State(resources: resources)
        FixtureRegistry.shared.register(self, host: host)
    }

    deinit {
        shutdown()
    }

    func url(percentEncodedPath: String, percentEncodedQuery: String? = nil) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = percentEncodedPath
        components.percentEncodedQuery = percentEncodedQuery
        return components.url!
    }

    func enqueue(_ fault: Fault, method: String, percentEncodedPath: String) {
        withState {
            $0.faults.append(
                ScheduledFault(
                    method: method.uppercased(),
                    percentEncodedPath: percentEncodedPath,
                    fault: fault
                )
            )
        }
    }

    func diagnostics() -> [Diagnostic] {
        withState { $0.diagnostics }
    }

    func shutdown() {
        guard let host = baseURL.host else {
            return
        }
        FixtureRegistry.shared.unregister(host: host)
    }
}

extension ControlledWebDAVFixture {
    fileprivate enum Action {
        case fail(URLError.Code)
        case interrupt(status: Int, headers: [String: String], prefix: Data, URLError.Code)
        case respond(status: Int, headers: [String: String], body: Data)
    }

    fileprivate func action(for request: URLRequest) -> Action {
        let method = (request.httpMethod ?? "GET").uppercased()
        let path = request.url.flatMap(Self.percentEncodedPath) ?? ""
        let body: Data
        switch Self.body(for: request) {
        case .success(let data):
            body = data
        case .failure:
            return withState { state in
                let action = Action.fail(URLError.Code.cannotDecodeContentData)
                state.diagnostics.append(
                    Diagnostic(
                        method: method,
                        percentEncodedPath: path,
                        bodyByteCount: 0,
                        statusCode: nil,
                        errorCode: action.errorCode
                    )
                )
                return action
            }
        }

        return withState { state in
            let action: Action
            if let fault = state.consumeFault(method: method, percentEncodedPath: path) {
                action = injectedAction(
                    fault,
                    method: method,
                    percentEncodedPath: path,
                    resources: state.resources
                )
            } else {
                action = normalAction(
                    for: request,
                    method: method,
                    percentEncodedPath: path,
                    body: body,
                    resources: &state.resources
                )
            }
            state.diagnostics.append(
                Diagnostic(
                    method: method,
                    percentEncodedPath: path,
                    bodyByteCount: body.count,
                    statusCode: action.statusCode,
                    errorCode: action.errorCode
                )
            )
            return action
        }
    }

    private func normalAction(
        for request: URLRequest,
        method: String,
        percentEncodedPath: String,
        body: Data,
        resources: inout [String: ResourceState]
    ) -> Action {
        switch method {
        case "PROPFIND":
            return propfindAction(request: request, percentEncodedPath: percentEncodedPath)
        case "GET":
            return getAction(percentEncodedPath: percentEncodedPath, resources: resources)
        case "PUT":
            return putAction(
                request: request,
                percentEncodedPath: percentEncodedPath,
                body: body,
                resources: &resources
            )
        default:
            return .respond(
                status: 405,
                headers: ["Allow": "PROPFIND, GET, PUT", "Content-Length": "0"],
                body: Data()
            )
        }
    }

    private func propfindAction(request: URLRequest, percentEncodedPath: String) -> Action {
        guard
            percentEncodedPath == contract.propfind.percentEncodedPath,
            request.value(forHTTPHeaderField: "Depth") == contract.propfind.depth
        else {
            return .respond(
                status: 400,
                headers: ["Content-Length": "0"],
                body: Data()
            )
        }
        return .respond(
            status: 207,
            headers: [
                "Content-Length": String(propfindBody.count),
                "Content-Type": "application/xml; charset=utf-8",
            ],
            body: propfindBody
        )
    }

    private func getAction(
        percentEncodedPath: String,
        resources: [String: ResourceState]
    ) -> Action {
        guard let resource = resources[percentEncodedPath] else {
            return .respond(status: 404, headers: ["Content-Length": "0"], body: Data())
        }
        guard resource.kind == .file else {
            return .respond(status: 405, headers: ["Content-Length": "0"], body: Data())
        }
        return .respond(
            status: 200,
            headers: resource.responseHeaders,
            body: resource.body
        )
    }

    private func putAction(
        request: URLRequest,
        percentEncodedPath: String,
        body: Data,
        resources: inout [String: ResourceState]
    ) -> Action {
        guard var resource = resources[percentEncodedPath], resource.kind == .file else {
            return .respond(status: 404, headers: ["Content-Length": "0"], body: Data())
        }
        guard let condition = request.value(forHTTPHeaderField: "If-Match") else {
            return .respond(status: 428, headers: ["Content-Length": "0"], body: Data())
        }
        guard
            let etag = resource.etag,
            !etag.hasPrefix("W/"),
            condition == etag
        else {
            return .respond(status: 412, headers: ["Content-Length": "0"], body: Data())
        }

        resource.revision += 1
        resource.body = body
        resource.etag = "\"\(resource.id)-v\(resource.revision)\""
        resources[percentEncodedPath] = resource
        return .respond(status: 204, headers: ["Content-Length": "0"], body: Data())
    }

    private func injectedAction(
        _ fault: Fault,
        method: String,
        percentEncodedPath: String,
        resources: [String: ResourceState]
    ) -> Action {
        switch fault {
        case .httpStatus(let status, let headers):
            return .respond(
                status: status,
                headers: headers.merging(["Content-Length": "0"]) { current, _ in current },
                body: Data()
            )
        case .urlError(let code):
            return .fail(code)
        case .interrupted(let byteCount, let code):
            guard
                method == "GET",
                let resource = resources[percentEncodedPath],
                resource.kind == .file
            else {
                return .fail(.badServerResponse)
            }
            return .interrupt(
                status: 200,
                headers: resource.responseHeaders,
                prefix: resource.body.prefix(max(0, byteCount)),
                code
            )
        }
    }

    private static func percentEncodedPath(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath
    }

    private static func body(for request: URLRequest) -> BodyRead {
        if let body = request.httpBody {
            return .success(body)
        }
        guard let stream = request.httpBodyStream else {
            return .success(Data())
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                continue
            }
            if count == 0, stream.streamStatus == .atEnd {
                return .success(data)
            }
            return .failure
        }
    }

    private static func readFixtureFile(_ path: String, below root: URL) throws -> Data {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard
            !path.hasPrefix("/"),
            !components.contains(""),
            !components.contains("."),
            !components.contains("..")
        else {
            throw FixtureError.invalidResourcePath
        }

        let resolved = root.appendingPathComponent(path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else {
            throw FixtureError.invalidResourcePath
        }
        return try Data(contentsOf: resolved)
    }

    @discardableResult
    private func withState<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}

extension ControlledWebDAVFixture.Action {
    fileprivate var statusCode: Int? {
        switch self {
        case .fail:
            nil
        case .interrupt(let status, _, _, _), .respond(let status, _, _):
            status
        }
    }

    fileprivate var errorCode: Int? {
        switch self {
        case .fail(let code), .interrupt(_, _, _, let code):
            code.rawValue
        case .respond:
            nil
        }
    }
}

private struct WebDAVFixtureContract: Decodable, Sendable {
    let schemaVersion: Int
    let fixture: Fixture
    let propfind: Propfind
    let resources: [Resource]

    struct Fixture: Decodable, Sendable {
        let milestone: String
        let synthetic: Bool
        let containsRealUserContent: Bool
    }

    struct Propfind: Decodable, Sendable {
        let percentEncodedPath: String
        let depth: String
        let body: String
    }

    struct Resource: Decodable, Sendable {
        let id: String
        let percentEncodedPath: String
        let kind: ResourceKind
        let body: String?
        let etag: String?
        let lastModified: String?
    }
}

private enum ResourceKind: String, Decodable, Sendable {
    case collection
    case file
}

private struct ResourceState: Sendable {
    let id: String
    let kind: ResourceKind
    var body: Data
    var etag: String?
    let lastModified: String?
    var revision: Int

    var responseHeaders: [String: String] {
        var headers = [
            "Content-Length": String(body.count),
            "Content-Type": "text/markdown; charset=utf-8",
        ]
        headers["ETag"] = etag
        headers["Last-Modified"] = lastModified
        return headers
    }
}

private struct ScheduledFault: Sendable {
    let method: String
    let percentEncodedPath: String
    let fault: ControlledWebDAVFixture.Fault
}

private enum BodyRead {
    case failure
    case success(Data)
}

private struct State {
    var resources: [String: ResourceState]
    var faults: [ScheduledFault] = []
    var diagnostics: [ControlledWebDAVFixture.Diagnostic] = []

    mutating func consumeFault(method: String, percentEncodedPath: String)
        -> ControlledWebDAVFixture.Fault?
    {
        guard
            let index = faults.firstIndex(where: {
                $0.method == method && $0.percentEncodedPath == percentEncodedPath
            })
        else {
            return nil
        }
        return faults.remove(at: index).fault
    }
}

private enum FixtureError: Error {
    case invalidBaseURL
    case invalidContract
    case invalidResourcePath
}

private final class WeakFixture {
    weak var value: ControlledWebDAVFixture?

    init(_ value: ControlledWebDAVFixture) {
        self.value = value
    }
}

private final class FixtureRegistry: @unchecked Sendable {
    static let shared = FixtureRegistry()

    private let lock = NSLock()
    private var fixtures: [String: WeakFixture] = [:]

    func register(_ fixture: ControlledWebDAVFixture, host: String) {
        lock.lock()
        fixtures[host] = WeakFixture(fixture)
        lock.unlock()
    }

    func unregister(host: String) {
        lock.lock()
        fixtures[host] = nil
        lock.unlock()
    }

    func fixture(host: String) -> ControlledWebDAVFixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixtures[host]?.value
    }
}

final class ControlledWebDAVURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        guard
            request.url?.scheme == "https",
            let host = request.url?.host
        else {
            return false
        }
        return FixtureRegistry.shared.fixture(host: host) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let url = request.url,
            let host = url.host,
            let fixture = FixtureRegistry.shared.fixture(host: host)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch fixture.action(for: request) {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .interrupt(let status, let headers, let prefix, let code):
            client?.urlProtocol(
                self,
                didReceive: response(url: url, status: status, headers: headers),
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: prefix)
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .respond(let status, let headers, let body):
            client?.urlProtocol(
                self,
                didReceive: response(url: url, status: status, headers: headers),
                cacheStoragePolicy: .notAllowed
            )
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private func response(url: URL, status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}

final class ControlledWebDAVDataCapture: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Result: @unchecked Sendable {
        let data: Data
        let response: URLResponse?
        let error: Error?
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Result, Never>?
    private var data = Data()
    private var hasStarted = false
    private var session: URLSession?

    func load(url: URL, configuration: URLSessionConfiguration) async -> Result {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !hasStarted else {
                lock.unlock()
                continuation.resume(
                    returning: Result(
                        data: Data(),
                        response: nil,
                        error: URLError(.cancelled)
                    )
                )
                return
            }
            hasStarted = true
            self.continuation = continuation
            let session = URLSession(
                configuration: configuration,
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            lock.unlock()
            session.dataTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        self.data.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let result = Result(data: data, response: task.response, error: error)
        let continuation = continuation
        self.continuation = nil
        self.session = nil
        lock.unlock()

        session.invalidateAndCancel()
        continuation?.resume(returning: result)
    }
}
