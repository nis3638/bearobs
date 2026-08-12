import Foundation
import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class CredentialStoreTests: XCTestCase {
    func testUsesFixedDescriptorForEveryOperationAndKeepsUsernameInsideEnvelope() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let first = Credentials(username: "private-user", applicationPassword: "private-pass")
        let second = Credentials(
            username: "replacement-user", applicationPassword: "replacement-pass")

        try store.save(first, overwrite: false)
        XCTAssertEqual(try store.load(), first)
        try store.save(second, overwrite: true)
        try store.delete()

        XCTAssertEqual(
            client.calls.map(\.operation),
            [.add, .copy, .add, .update, .delete, .containsItem]
        )
        XCTAssertEqual(
            client.calls.compactMap(\.descriptor),
            Array(repeating: expectedDescriptor, count: 4)
        )
        XCTAssertEqual(
            client.calls.compactMap(\.identity),
            [expectedIdentity, expectedIdentity]
        )
        XCTAssertFalse(expectedDescriptor.service.contains(first.username))
        XCTAssertFalse(expectedDescriptor.account.contains(first.username))

        let addedData = try XCTUnwrap(client.calls.first?.data)
        let envelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: addedData) as? [String: Any]
        )
        XCTAssertEqual(envelope["version"] as? Int, 1)
        XCTAssertEqual(envelope["username"] as? String, first.username)
        XCTAssertEqual(envelope["applicationPassword"] as? String, first.applicationPassword)
    }

    func testLoadReturnsNilWhenItemDoesNotExist() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)

        XCTAssertNil(try store.load())
        XCTAssertEqual(client.calls.map(\.operation), [.copy])
        XCTAssertEqual(client.calls.first?.descriptor, expectedDescriptor)
    }

    func testSaveWithoutOverwriteRejectsDuplicateAndPreservesExistingItem() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let original = Credentials(username: "original", applicationPassword: "one")
        let replacement = Credentials(username: "replacement", applicationPassword: "two")

        try store.save(original, overwrite: false)
        client.clearCalls()

        assertStoreError(.itemAlreadyExists) {
            try store.save(replacement, overwrite: false)
        }

        XCTAssertEqual(client.calls.map(\.operation), [.add])
        XCTAssertEqual(try store.load(), original)
    }

    func testSaveWithOverwriteAddsWhenItemDoesNotExist() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let credentials = Credentials(username: "new-user", applicationPassword: "new-pass")

        try store.save(credentials, overwrite: true)

        XCTAssertEqual(client.calls.map(\.operation), [.add])
        XCTAssertEqual(try store.load(), credentials)
    }

    func testSaveWithOverwriteUsesAddThenUpdateWhenItemExists() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let original = Credentials(username: "original", applicationPassword: "one")
        let replacement = Credentials(username: "replacement", applicationPassword: "two")
        try store.save(original, overwrite: false)
        client.clearCalls()

        try store.save(replacement, overwrite: true)

        XCTAssertEqual(client.calls.map(\.operation), [.add, .update])
        XCTAssertEqual(try store.load(), replacement)
    }

    func testOverwriteRetriesWholeAddUpdateSequenceOnceAfterItemNotFoundRace() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let original = Credentials(username: "original", applicationPassword: "one")
        let replacement = Credentials(username: "replacement", applicationPassword: "two")
        try store.save(original, overwrite: false)
        client.clearCalls()
        client.updateInterferences = [.remove]

        try store.save(replacement, overwrite: true)

        XCTAssertEqual(client.calls.map(\.operation), [.add, .update, .add])
        XCTAssertEqual(try store.load(), replacement)
    }

    func testOverwriteStopsAfterOneBoundedRetryWhenRaceRepeats() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let original = Credentials(username: "original", applicationPassword: "one")
        let replacement = Credentials(username: "replacement", applicationPassword: "two")
        try store.save(original, overwrite: false)
        client.clearCalls()
        client.addInterferences = [.none, .upsert(Data("competitor".utf8))]
        client.updateInterferences = [.remove, .remove]

        assertClientError(.itemNotFound) {
            try store.save(replacement, overwrite: true)
        }

        XCTAssertEqual(client.calls.map(\.operation), [.add, .update, .add, .update])
        XCTAssertNil(client.data(for: expectedDescriptor))
    }

    func testSaveAcceptsCredentialComponentAtExactUTF8ByteLimit() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let credentials = Credentials(
            username: String(repeating: "a", count: 4_096),
            applicationPassword: "password"
        )

        try store.save(credentials, overwrite: false)

        XCTAssertEqual(client.calls.map(\.operation), [.add])
        XCTAssertEqual(try store.load(), credentials)
    }

    func testSaveRejectsEmptyOversizedAndControlCharacterComponentsBeforeKeychainAccess() {
        let invalidCredentials = [
            Credentials(username: "", applicationPassword: "password"),
            Credentials(username: "username", applicationPassword: ""),
            Credentials(username: "line\nbreak", applicationPassword: "password"),
            Credentials(username: "username", applicationPassword: "nul\0byte"),
            Credentials(
                username: String(repeating: "a", count: 4_097), applicationPassword: "password"),
            Credentials(
                username: "username", applicationPassword: String(repeating: "b", count: 4_097)),
        ]

        for credentials in invalidCredentials {
            let client = FakeKeychainClient()
            let store = KeychainCredentialStore(client: client)

            assertStoreError(.invalidCredentials) {
                try store.save(credentials, overwrite: false)
            }
            XCTAssertTrue(client.calls.isEmpty)
        }
    }

    func testSaveRejectsEnvelopeExpandedBeyondLimitBeforeKeychainAccess() {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)
        let credentials = Credentials(
            username: String(repeating: "\\", count: 4_096),
            applicationPassword: String(repeating: "\\", count: 4_096)
        )

        assertStoreError(.invalidCredentials) {
            try store.save(credentials, overwrite: false)
        }

        XCTAssertTrue(client.calls.isEmpty)
    }

    func testLoadRejectsInvalidCredentialComponentsFromCurrentEnvelope() throws {
        let invalidCredentials = [
            Credentials(username: "", applicationPassword: "password"),
            Credentials(username: "username", applicationPassword: ""),
            Credentials(username: "line\nbreak", applicationPassword: "password"),
            Credentials(username: "username", applicationPassword: "nul\0byte"),
            Credentials(
                username: String(repeating: "a", count: 4_097), applicationPassword: "password"),
            Credentials(
                username: "username", applicationPassword: String(repeating: "b", count: 4_097)),
        ]

        for credentials in invalidCredentials {
            let client = FakeKeychainClient()
            client.seed(
                try makeEnvelopeData(
                    version: 1,
                    username: credentials.username,
                    applicationPassword: credentials.applicationPassword
                ),
                for: expectedDescriptor
            )
            let store = KeychainCredentialStore(client: client)

            assertStoreError(.invalidCredentials) {
                try store.load()
            }
            XCTAssertEqual(client.calls.map(\.operation), [.copy])
        }
    }

    func testLoadRejectsEnvelopeBeyondMaximumSizeAsMalformed() {
        let client = FakeKeychainClient()
        client.seed(Data(repeating: 0x20, count: 16_385), for: expectedDescriptor)
        let store = KeychainCredentialStore(client: client)

        assertStoreError(.malformedEnvelope) {
            try store.load()
        }

        XCTAssertEqual(client.calls.map(\.operation), [.copy])
    }

    func testLoadClassifiesCurrentVersionShapeFailuresAsMalformed() {
        let malformedPayloads = [
            Data("not-json".utf8),
            Data(#"{"username":"u","applicationPassword":"p"}"#.utf8),
            Data(#"{"version":1,"username":"u"}"#.utf8),
            Data(#"{"version":1,"username":7,"applicationPassword":"p"}"#.utf8),
            Data(#"{"version":"1","username":"u","applicationPassword":"p"}"#.utf8),
        ]

        for payload in malformedPayloads {
            let client = FakeKeychainClient()
            client.seed(payload, for: expectedDescriptor)
            let store = KeychainCredentialStore(client: client)

            assertStoreError(.malformedEnvelope) {
                try store.load()
            }
            XCTAssertEqual(client.calls.map(\.operation), [.copy])
        }
    }

    func testLoadClassifiesUnknownVersionBeforeDecodingVersionSpecificShape() {
        let client = FakeKeychainClient()
        client.seed(Data(#"{"version":2,"principal":"u"}"#.utf8), for: expectedDescriptor)
        let store = KeychainCredentialStore(client: client)

        assertStoreError(.unsupportedEnvelopeVersion(2)) {
            try store.load()
        }

        XCTAssertEqual(client.calls.map(\.operation), [.copy])
    }

    func testDeleteUsesStableIdentityAndIndependentlyConfirmsAbsence() throws {
        let client = FakeKeychainClient()
        client.seed(Data("credential".utf8), for: expectedDescriptor)
        let store = KeychainCredentialStore(client: client)

        try store.delete()

        XCTAssertEqual(client.calls.map(\.operation), [.delete, .containsItem])
        XCTAssertEqual(
            client.calls.compactMap(\.identity),
            [expectedIdentity, expectedIdentity]
        )
        XCTAssertNil(client.data(for: expectedDescriptor))
    }

    func testDeleteNeverCrossesKeychainImplementationBoundary() throws {
        let driftedDescriptor = KeychainItemDescriptor(
            service: expectedIdentity.service,
            account: expectedIdentity.account,
            accessibility: .whenUnlockedThisDeviceOnly,
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        let client = FakeKeychainClient()
        client.seed(Data("credential".utf8), for: driftedDescriptor)
        let store = KeychainCredentialStore(client: client)

        try store.delete()

        XCTAssertEqual(client.calls.map(\.operation), [.delete, .containsItem])
        XCTAssertTrue(client.calls.allSatisfy { $0.identity == expectedIdentity })
        XCTAssertEqual(client.data(for: driftedDescriptor), Data("credential".utf8))
    }

    func testDeleteDoesNotTreatItemNotFoundAsProofWhenStableIdentityStillExists() throws {
        let client = FakeKeychainClient()
        client.seed(Data("credential".utf8), for: expectedDescriptor)
        client.deleteBehavior = .reportItemNotFoundWithoutDeleting
        let store = KeychainCredentialStore(client: client)

        assertStoreError(.deletionNotConfirmed) {
            try store.delete()
        }

        XCTAssertEqual(client.calls.map(\.operation), [.delete, .containsItem])
        XCTAssertEqual(client.data(for: expectedDescriptor), Data("credential".utf8))
    }

    func testDeleteRejectsSuccessWhenStableIdentityStillExists() throws {
        let client = FakeKeychainClient()
        client.seed(Data("credential".utf8), for: expectedDescriptor)
        client.deleteBehavior = .succeedWithoutDeleting
        let store = KeychainCredentialStore(client: client)

        assertStoreError(.deletionNotConfirmed) {
            try store.delete()
        }

        XCTAssertEqual(client.calls.map(\.operation), [.delete, .containsItem])
        XCTAssertEqual(client.data(for: expectedDescriptor), Data("credential".utf8))
    }

    func testDeleteRemainsIdempotentWhenStableIdentityDoesNotExist() throws {
        let client = FakeKeychainClient()
        let store = KeychainCredentialStore(client: client)

        try store.delete()

        XCTAssertEqual(client.calls.map(\.operation), [.delete, .containsItem])
        XCTAssertEqual(
            client.calls.compactMap(\.identity),
            [expectedIdentity, expectedIdentity]
        )
    }

    func testFakeModelsDuplicateAndItemNotFoundInsteadOfSilentlyOverwriting() throws {
        let client = FakeKeychainClient()
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)

        try client.add(original, for: expectedDescriptor)
        assertClientError(.duplicateItem) {
            try client.add(replacement, for: expectedDescriptor)
        }
        XCTAssertEqual(client.data(for: expectedDescriptor), original)

        try client.delete(for: expectedIdentity)
        assertClientError(.itemNotFound) {
            try client.update(replacement, for: expectedDescriptor)
        }
        XCTAssertFalse(try client.containsItem(for: expectedIdentity))
        XCTAssertNil(client.data(for: expectedDescriptor))
    }
}

private let expectedDescriptor = KeychainItemDescriptor(
    service: "com.bearobs.m0-11.jianguoyun",
    account: "credentials-v1",
    accessibility: .whenUnlockedThisDeviceOnly,
    usesDataProtectionKeychain: false,
    synchronizable: false
)

private let expectedIdentity = GenericPasswordKeychainIdentity(
    service: "com.bearobs.m0-11.jianguoyun",
    account: "credentials-v1",
    usesDataProtectionKeychain: false,
    synchronizable: false
)

private func makeEnvelopeData(
    version: Int,
    username: String,
    applicationPassword: String
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: [
            "version": version,
            "username": username,
            "applicationPassword": applicationPassword,
        ],
        options: [.sortedKeys]
    )
}

private func assertStoreError<T>(
    _ expected: KeychainCredentialStoreError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> T
) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual(
            error as? KeychainCredentialStoreError,
            Optional(expected),
            file: file,
            line: line
        )
    }
}

private func assertClientError<T>(
    _ expected: GenericPasswordKeychainClientError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () throws -> T
) {
    XCTAssertThrowsError(try body(), file: file, line: line) { error in
        XCTAssertEqual(
            error as? GenericPasswordKeychainClientError,
            Optional(expected),
            file: file,
            line: line
        )
    }
}

private final class FakeKeychainClient: GenericPasswordKeychainClient {
    enum Operation: Equatable {
        case add
        case copy
        case update
        case delete
        case containsItem
    }

    enum DeleteBehavior {
        case removeMatchingItems
        case reportItemNotFoundWithoutDeleting
        case succeedWithoutDeleting
    }

    enum Interference {
        case none
        case remove
        case upsert(Data)
    }

    struct Call {
        let operation: Operation
        let descriptor: KeychainItemDescriptor?
        let identity: GenericPasswordKeychainIdentity?
        let data: Data?
    }

    private struct Item {
        let descriptor: KeychainItemDescriptor
        var data: Data
    }

    private var items: [Item] = []
    private(set) var calls: [Call] = []
    var addInterferences: [Interference] = []
    var updateInterferences: [Interference] = []
    var deleteBehavior: DeleteBehavior = .removeMatchingItems

    func add(_ data: Data, for descriptor: KeychainItemDescriptor) throws {
        calls.append(
            Call(operation: .add, descriptor: descriptor, identity: nil, data: data)
        )
        apply(nextInterference(from: &addInterferences), for: descriptor)
        guard index(for: descriptor) == nil else {
            throw GenericPasswordKeychainClientError.duplicateItem
        }
        items.append(Item(descriptor: descriptor, data: data))
    }

    func copy(for descriptor: KeychainItemDescriptor) throws -> Data? {
        calls.append(
            Call(operation: .copy, descriptor: descriptor, identity: nil, data: nil)
        )
        return data(for: descriptor)
    }

    func update(_ data: Data, for descriptor: KeychainItemDescriptor) throws {
        calls.append(
            Call(operation: .update, descriptor: descriptor, identity: nil, data: data)
        )
        apply(nextInterference(from: &updateInterferences), for: descriptor)
        guard let itemIndex = index(for: descriptor) else {
            throw GenericPasswordKeychainClientError.itemNotFound
        }
        items[itemIndex].data = data
    }

    func delete(for identity: GenericPasswordKeychainIdentity) throws {
        calls.append(
            Call(operation: .delete, descriptor: nil, identity: identity, data: nil)
        )

        switch deleteBehavior {
        case .removeMatchingItems:
            let itemCount = items.count
            items.removeAll { matches($0.descriptor, identity: identity) }
            guard items.count != itemCount else {
                throw GenericPasswordKeychainClientError.itemNotFound
            }
        case .reportItemNotFoundWithoutDeleting:
            throw GenericPasswordKeychainClientError.itemNotFound
        case .succeedWithoutDeleting:
            return
        }
    }

    func containsItem(for identity: GenericPasswordKeychainIdentity) throws -> Bool {
        calls.append(
            Call(operation: .containsItem, descriptor: nil, identity: identity, data: nil)
        )
        return items.contains { matches($0.descriptor, identity: identity) }
    }

    func seed(_ data: Data, for descriptor: KeychainItemDescriptor) {
        upsert(data, for: descriptor)
    }

    func data(for descriptor: KeychainItemDescriptor) -> Data? {
        guard let itemIndex = index(for: descriptor) else {
            return nil
        }
        return items[itemIndex].data
    }

    func clearCalls() {
        calls.removeAll(keepingCapacity: true)
    }

    private func index(for descriptor: KeychainItemDescriptor) -> Int? {
        items.firstIndex { $0.descriptor == descriptor }
    }

    private func matches(
        _ descriptor: KeychainItemDescriptor,
        identity: GenericPasswordKeychainIdentity
    ) -> Bool {
        descriptor.service == identity.service
            && descriptor.account == identity.account
            && descriptor.usesDataProtectionKeychain == identity.usesDataProtectionKeychain
            && descriptor.synchronizable == identity.synchronizable
    }

    private func remove(for descriptor: KeychainItemDescriptor) {
        guard let itemIndex = index(for: descriptor) else {
            return
        }
        items.remove(at: itemIndex)
    }

    private func upsert(_ data: Data, for descriptor: KeychainItemDescriptor) {
        if let itemIndex = index(for: descriptor) {
            items[itemIndex].data = data
        } else {
            items.append(Item(descriptor: descriptor, data: data))
        }
    }

    private func nextInterference(from queue: inout [Interference]) -> Interference {
        guard !queue.isEmpty else {
            return .none
        }
        return queue.removeFirst()
    }

    private func apply(_ interference: Interference, for descriptor: KeychainItemDescriptor) {
        switch interference {
        case .none:
            return
        case .remove:
            remove(for: descriptor)
        case .upsert(let data):
            upsert(data, for: descriptor)
        }
    }
}
