import Foundation

public enum AuthenticationMethod: Equatable, Sendable {
    case basic
    case digest
    case serverTrust
    case other
}

public struct ChallengeContext: Equatable, Sendable {
    public let method: AuthenticationMethod
    public let host: String
    public let protocolName: String
    public let port: Int
    public let previousFailureCount: Int

    public init(
        method: AuthenticationMethod,
        host: String,
        protocolName: String,
        port: Int,
        previousFailureCount: Int
    ) {
        self.method = method
        self.host = host
        self.protocolName = protocolName
        self.port = port
        self.previousFailureCount = previousFailureCount
    }
}

public enum ChallengeDisposition: Equatable, Sendable {
    case useCredential
    case performDefaultHandling
    case reject
}

public struct ChallengePolicy: Sendable {
    public init() {}

    public func disposition(
        for context: ChallengeContext,
        credentialsAvailable: Bool
    ) -> ChallengeDisposition {
        if context.method == .serverTrust {
            return .performDefaultHandling
        }

        guard credentialsAvailable,
            context.method == .basic || context.method == .digest,
            context.host.caseInsensitiveCompare(JianguoyunEndpoint.host) == .orderedSame,
            context.protocolName.caseInsensitiveCompare(JianguoyunEndpoint.scheme) == .orderedSame,
            context.port == JianguoyunEndpoint.port,
            context.previousFailureCount == 0
        else {
            return .reject
        }
        return .useCredential
    }
}

public struct RedirectPolicy: Sendable {
    public init() {}

    public func shouldFollow(from _: URL, to _: URL) -> Bool {
        false
    }
}
