import Foundation

public protocol VerifierRemote: Sendable {
    func unauthenticatedDepthZeroStatus() async throws -> Int
    func list(path: VerifierPath?, depth: Int) async throws -> RemoteListing
    func makeCollection(path: VerifierPath) async throws -> Int
    func put(path: VerifierPath, body: Data, ifMatch: StrongETag?) async throws -> Int
    func get(path: VerifierPath) async throws -> RemoteRead
    func delete(path: VerifierPath, ifMatch: StrongETag?) async throws -> Int
}

public struct RemoteListing: Sendable, Equatable {
    public let statusCode: Int
    public let entries: [RemoteEntry]

    public init(statusCode: Int, entries: [RemoteEntry]) {
        self.statusCode = statusCode
        self.entries = entries
    }
}

public struct RemoteEntry: Sendable, Equatable {
    public let path: VerifierPath?
    public let isCollection: Bool
    public let etagHeader: String?

    public init(path: VerifierPath?, isCollection: Bool, etagHeader: String?) {
        self.path = path
        self.isCollection = isCollection
        self.etagHeader = etagHeader
    }
}

public struct RemoteRead: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data
    public let etagHeader: String?

    public init(statusCode: Int, body: Data, etagHeader: String?) {
        self.statusCode = statusCode
        self.body = body
        self.etagHeader = etagHeader
    }
}

public enum VerifierFailure: Error, Sendable, Equatable {
    case authenticationProbeFailed
    case authenticationChallengeRejected
    case authenticationCredentialsRejected
    case dedicatedDirectoryUnavailable
    case dedicatedDirectoryHTTPStatus(depth: Int, status: Int)
    case dedicatedDirectoryNotEmpty
    case invalidHTTPStatus
    case missingStrongETag
    case responseBodyMismatch
    case staleWriteWasAccepted
    case staleWriteChangedBody
    case staleDeleteWasAccepted
    case staleDeleteChangedResource
    case cleanupFailed
    case manualReviewRequired
    case runAlreadyInProgress
    case remoteOperationFailed
}
