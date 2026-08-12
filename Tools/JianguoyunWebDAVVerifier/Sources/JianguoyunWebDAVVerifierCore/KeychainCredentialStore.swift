import Foundation
import Security

public enum KeychainAccessibility: Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
}

public struct KeychainItemDescriptor: Equatable, Sendable {
    public let service: String
    public let account: String
    public let accessibility: KeychainAccessibility
    public let usesDataProtectionKeychain: Bool
    public let synchronizable: Bool

    public init(
        service: String,
        account: String,
        accessibility: KeychainAccessibility,
        usesDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) {
        self.service = service
        self.account = account
        self.accessibility = accessibility
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
        self.synchronizable = synchronizable
    }
}

public struct GenericPasswordKeychainIdentity: Equatable, Sendable {
    public let service: String
    public let account: String
    public let usesDataProtectionKeychain: Bool
    public let synchronizable: Bool

    public init(
        service: String,
        account: String,
        usesDataProtectionKeychain: Bool,
        synchronizable: Bool
    ) {
        self.service = service
        self.account = account
        self.usesDataProtectionKeychain = usesDataProtectionKeychain
        self.synchronizable = synchronizable
    }
}

public protocol GenericPasswordKeychainClient {
    func add(_ data: Data, for descriptor: KeychainItemDescriptor) throws
    func copy(for descriptor: KeychainItemDescriptor) throws -> Data?
    func update(_ data: Data, for descriptor: KeychainItemDescriptor) throws
    func delete(for identity: GenericPasswordKeychainIdentity) throws
    func containsItem(for identity: GenericPasswordKeychainIdentity) throws -> Bool
}

public enum GenericPasswordKeychainClientError: Error, Equatable, Sendable {
    case duplicateItem
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case unexpectedCopyResult
}

public struct SecurityGenericPasswordKeychainClient: GenericPasswordKeychainClient, Sendable {
    public init() {}

    public func add(_ data: Data, for descriptor: KeychainItemDescriptor) throws {
        var attributes = descriptorQuery(for: descriptor)
        attributes[kSecValueData] = data

        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            throw GenericPasswordKeychainClientError.duplicateItem
        default:
            throw GenericPasswordKeychainClientError.unexpectedStatus(status)
        }
    }

    public func copy(for descriptor: KeychainItemDescriptor) throws -> Data? {
        var attributes = descriptorQuery(for: descriptor)
        attributes[kSecReturnData] = true
        attributes[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw GenericPasswordKeychainClientError.unexpectedCopyResult
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw GenericPasswordKeychainClientError.unexpectedStatus(status)
        }
    }

    public func update(_ data: Data, for descriptor: KeychainItemDescriptor) throws {
        let attributesToUpdate: [CFString: Any] = [
            kSecValueData: data
        ]
        let status = SecItemUpdate(
            descriptorQuery(for: descriptor) as CFDictionary,
            attributesToUpdate as CFDictionary
        )
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw GenericPasswordKeychainClientError.itemNotFound
        default:
            throw GenericPasswordKeychainClientError.unexpectedStatus(status)
        }
    }

    public func delete(for identity: GenericPasswordKeychainIdentity) throws {
        let status = SecItemDelete(identityQuery(for: identity) as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw GenericPasswordKeychainClientError.itemNotFound
        default:
            throw GenericPasswordKeychainClientError.unexpectedStatus(status)
        }
    }

    public func containsItem(for identity: GenericPasswordKeychainIdentity) throws -> Bool {
        var attributes = identityQuery(for: identity)
        attributes[kSecReturnAttributes] = true
        attributes[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw GenericPasswordKeychainClientError.unexpectedStatus(status)
        }
    }

    private func descriptorQuery(for descriptor: KeychainItemDescriptor) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: descriptor.service,
            kSecAttrAccount: descriptor.account,
        ]
        if descriptor.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
            query[kSecAttrAccessible] = descriptor.accessibility.securityAttribute
            query[kSecAttrSynchronizable] = descriptor.synchronizable
        }
        return query
    }

    private func identityQuery(
        for identity: GenericPasswordKeychainIdentity
    ) -> [CFString: Any] {
        var query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: identity.service,
            kSecAttrAccount: identity.account,
        ]
        if identity.usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain] = true
            query[kSecAttrSynchronizable] = identity.synchronizable
        }
        return query
    }
}

public enum KeychainCredentialStoreError: Error, Equatable, Sendable {
    case itemAlreadyExists
    case invalidCredentials
    case malformedEnvelope
    case unsupportedEnvelopeVersion(Int)
    case deletionNotConfirmed
}

public struct KeychainCredentialStore {
    private static let currentEnvelopeVersion = 1
    private static let maximumCredentialBytes = 4_096
    private static let maximumEnvelopeBytes = 16_384
    private static let identity = GenericPasswordKeychainIdentity(
        service: "com.bearobs.m0-11.jianguoyun",
        account: "credentials-v1",
        usesDataProtectionKeychain: false,
        synchronizable: false
    )
    private static let descriptor = KeychainItemDescriptor(
        service: identity.service,
        account: identity.account,
        accessibility: .whenUnlockedThisDeviceOnly,
        usesDataProtectionKeychain: false,
        synchronizable: false
    )

    private let client: any GenericPasswordKeychainClient

    public init() {
        self.init(client: SecurityGenericPasswordKeychainClient())
    }

    public init(client: any GenericPasswordKeychainClient) {
        self.client = client
    }

    public func save(_ credentials: Credentials, overwrite: Bool) throws {
        try validate(credentials)

        var data = try encode(credentials)
        defer {
            data.resetBytes(in: data.startIndex..<data.endIndex)
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw KeychainCredentialStoreError.invalidCredentials
        }

        if overwrite {
            try addOrUpdate(data)
        } else {
            try addWithoutOverwrite(data)
        }
    }

    public func load() throws -> Credentials? {
        guard var data = try client.copy(for: Self.descriptor) else {
            return nil
        }
        defer {
            data.resetBytes(in: data.startIndex..<data.endIndex)
        }
        guard data.count <= Self.maximumEnvelopeBytes else {
            throw KeychainCredentialStoreError.malformedEnvelope
        }

        let envelope = try decodeEnvelope(from: data)
        let credentials = Credentials(
            username: envelope.username,
            applicationPassword: envelope.applicationPassword
        )
        try validate(credentials)
        return credentials
    }

    public func delete() throws {
        do {
            try client.delete(for: Self.identity)
        } catch GenericPasswordKeychainClientError.itemNotFound {
            // A failed delete is not proof of absence. Confirm independently below.
        }

        guard try !client.containsItem(for: Self.identity) else {
            throw KeychainCredentialStoreError.deletionNotConfirmed
        }
    }

    private func encode(_ credentials: Credentials) throws -> Data {
        let envelope = CredentialEnvelope(
            version: Self.currentEnvelopeVersion,
            username: credentials.username,
            applicationPassword: credentials.applicationPassword
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private func addWithoutOverwrite(_ data: Data) throws {
        do {
            try client.add(data, for: Self.descriptor)
        } catch GenericPasswordKeychainClientError.duplicateItem {
            throw KeychainCredentialStoreError.itemAlreadyExists
        }
    }

    private func addOrUpdate(_ data: Data) throws {
        do {
            try addOrUpdateOnce(data)
        } catch GenericPasswordKeychainClientError.itemNotFound {
            try addOrUpdateOnce(data)
        }
    }

    private func addOrUpdateOnce(_ data: Data) throws {
        do {
            try client.add(data, for: Self.descriptor)
        } catch GenericPasswordKeychainClientError.duplicateItem {
            try client.update(data, for: Self.descriptor)
        }
    }

    private func decodeEnvelope(from data: Data) throws -> CredentialEnvelope {
        let decoder = JSONDecoder()
        let version: CredentialEnvelopeVersion
        do {
            version = try decoder.decode(CredentialEnvelopeVersion.self, from: data)
        } catch {
            throw KeychainCredentialStoreError.malformedEnvelope
        }

        guard version.version == Self.currentEnvelopeVersion else {
            throw KeychainCredentialStoreError.unsupportedEnvelopeVersion(version.version)
        }

        do {
            return try decoder.decode(CredentialEnvelope.self, from: data)
        } catch {
            throw KeychainCredentialStoreError.malformedEnvelope
        }
    }

    private func validate(_ credentials: Credentials) throws {
        guard Self.isValidCredentialComponent(credentials.username),
            Self.isValidCredentialComponent(credentials.applicationPassword)
        else {
            throw KeychainCredentialStoreError.invalidCredentials
        }
    }

    private static func isValidCredentialComponent(_ value: String) -> Bool {
        let byteCount = value.utf8.count
        guard byteCount > 0, byteCount <= maximumCredentialBytes else {
            return false
        }
        return !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}

private struct CredentialEnvelope: Codable {
    let version: Int
    let username: String
    let applicationPassword: String
}

private struct CredentialEnvelopeVersion: Decodable {
    let version: Int
}

extension KeychainAccessibility {
    fileprivate var securityAttribute: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}
