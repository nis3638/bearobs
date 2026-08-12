public struct Credentials: Equatable, Sendable {
    public let username: String
    public let applicationPassword: String

    public init(username: String, applicationPassword: String) {
        self.username = username
        self.applicationPassword = applicationPassword
    }
}
