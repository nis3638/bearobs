import Foundation

public enum JianguoyunEndpoint {
    public static let scheme = "https"
    public static let host = "dav.jianguoyun.com"
    public static let port = 443
    public static let davPath = "/dav/"

    public static let baseURL: URL = {
        guard let url = URL(string: "https://dav.jianguoyun.com/dav/") else {
            preconditionFailure("invalid fixed Jianguoyun endpoint")
        }
        return url
    }()
}

public enum RemoteScopeError: Error, Equatable, Sendable {
    case malformedHref
    case forbiddenURLComponents
    case forbiddenOrigin
    case outsideDAVRoot
    case invalidPath
    case outsideDedicatedRoot
    case invalidGeneratedURL
}

public struct RemoteScope {
    public let dedicatedRoot: VerifierPath

    public init(dedicatedRoot: VerifierPath) {
        self.dedicatedRoot = dedicatedRoot
    }

    public var rootURL: URL {
        let value =
            JianguoyunEndpoint.baseURL.absoluteString
            + dedicatedRoot.percentEncodedRelativePath
            + "/"
        guard let url = URL(string: value) else {
            preconditionFailure("VerifierPath produced an invalid root URL")
        }
        return url
    }

    public func resourceURL(for path: VerifierPath) throws -> URL {
        let value = rootURL.absoluteString + path.percentEncodedRelativePath
        guard let url = URL(string: value) else {
            throw RemoteScopeError.invalidGeneratedURL
        }
        return url
    }

    public func relativePath(forHref href: String) throws -> VerifierPath? {
        guard !href.isEmpty, let components = URLComponents(string: href) else {
            throw RemoteScopeError.malformedHref
        }
        guard components.user == nil,
            components.password == nil,
            components.percentEncodedQuery == nil,
            components.percentEncodedFragment == nil
        else {
            throw RemoteScopeError.forbiddenURLComponents
        }

        try validateLocation(of: components, originalHref: href)

        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix(JianguoyunEndpoint.davPath) else {
            throw RemoteScopeError.outsideDAVRoot
        }

        var encodedRelativePath = String(
            encodedPath.dropFirst(JianguoyunEndpoint.davPath.count)
        )
        if encodedRelativePath.hasSuffix("/") {
            encodedRelativePath.removeLast()
        }
        guard !encodedRelativePath.isEmpty else {
            throw RemoteScopeError.outsideDedicatedRoot
        }

        let scopedPath: VerifierPath
        do {
            scopedPath = try VerifierPath(percentEncodedRelativePath: encodedRelativePath)
        } catch {
            throw RemoteScopeError.invalidPath
        }

        let root = dedicatedRoot.description
        if scopedPath.description == root {
            return nil
        }

        let childPrefix = root + "/"
        guard scopedPath.description.hasPrefix(childPrefix) else {
            throw RemoteScopeError.outsideDedicatedRoot
        }

        let child = String(scopedPath.description.dropFirst(childPrefix.count))
        do {
            return try VerifierPath(decodedRelativePath: child)
        } catch {
            throw RemoteScopeError.invalidPath
        }
    }

    private func validateLocation(
        of components: URLComponents,
        originalHref: String
    ) throws {
        let isAbsolute =
            components.scheme != nil
            || components.host != nil
            || components.port != nil
            || originalHref.hasPrefix("//")

        if isAbsolute {
            guard let scheme = components.scheme,
                scheme.caseInsensitiveCompare(JianguoyunEndpoint.scheme) == .orderedSame,
                let host = components.host,
                host.caseInsensitiveCompare(JianguoyunEndpoint.host) == .orderedSame,
                components.port == nil || components.port == JianguoyunEndpoint.port
            else {
                throw RemoteScopeError.forbiddenOrigin
            }
            return
        }

        guard originalHref.hasPrefix("/"),
            !originalHref.hasPrefix("//"),
            components.scheme == nil,
            components.host == nil,
            components.port == nil
        else {
            throw RemoteScopeError.forbiddenOrigin
        }
    }
}
