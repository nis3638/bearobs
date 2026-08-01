import Foundation

struct ContentHash: Hashable, Codable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidSHA256Hex
    }

    let hex: String

    init(hex: String) throws {
        let canonical = hex.lowercased()
        guard canonical.utf8.count == 64,
            canonical.utf8.allSatisfy(Self.isHexDigit)
        else {
            throw ValidationError.invalidSHA256Hex
        }
        self.hex = canonical
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(hex: container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

struct StrongETag: Hashable, Codable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidOpaqueValue
    }

    private let opaqueValue: String

    init(headerValue: String) throws {
        guard headerValue.first == "\"",
            headerValue.last == "\"",
            headerValue.count >= 2
        else {
            throw ValidationError.invalidOpaqueValue
        }
        let opaqueValue = String(headerValue.dropFirst().dropLast())
        guard
            opaqueValue.unicodeScalars.allSatisfy({
                $0.value == 0x21
                    || ($0.value >= 0x23 && $0.value <= 0x7E)
                    || ($0.value >= 0x80 && $0.value <= 0xFF)
            })
        else {
            throw ValidationError.invalidOpaqueValue
        }
        self.opaqueValue = opaqueValue
    }

    var headerValue: String {
        "\"\(opaqueValue)\""
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(headerValue: container.decode(String.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(headerValue)
    }
}

enum RemoteWritePrecondition: Hashable, Codable, Sendable {
    case ifMatch(StrongETag)

    var headerValue: String {
        switch self {
        case .ifMatch(let tag): tag.headerValue
        }
    }
}

struct RemoteRevision: Hashable, Codable, Sendable {
    enum ValidationError: Error, Equatable, Sendable {
        case invalidIdentifier
    }

    let reliableIdentifier: String

    init(reliableIdentifier: String) throws {
        guard !reliableIdentifier.isEmpty,
            reliableIdentifier.unicodeScalars.allSatisfy({
                $0.value >= 0x20 && $0.value != 0x7F
            })
        else {
            throw ValidationError.invalidIdentifier
        }
        self.reliableIdentifier = reliableIdentifier
    }

    init(strongETag: StrongETag) {
        reliableIdentifier = "etag:\(strongETag.headerValue)"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            reliableIdentifier: container.decode(
                String.self,
                forKey: .reliableIdentifier
            )
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            reliableIdentifier,
            forKey: .reliableIdentifier
        )
    }

    private enum CodingKeys: String, CodingKey {
        case reliableIdentifier
    }
}

struct RemoteSnapshot: Hashable, Codable, Sendable {
    let revision: RemoteRevision?
    let writePrecondition: RemoteWritePrecondition?
    let verifiedContentHash: ContentHash?
}

struct SyncBaselineState: Hashable, Codable, Sendable {
    let localHash: ContentHash
    let remoteRevision: RemoteRevision?
}

enum LocalResourceState: Hashable, Sendable {
    case missing
    case present(ContentHash)
    case unsupported
}

enum RemoteResourceState: Hashable, Sendable {
    case missing
    case present(RemoteSnapshot)
    case unsupported
}

enum SyncPlanningContext: Hashable, Sendable {
    case tracked(SyncBaselineState)
    case initialImport
    case conservativeRecovery
}

enum LocalExpectation: Hashable, Sendable {
    case missing
    case matching(ContentHash)
}

struct DownloadPlan: Hashable, Sendable {
    let expectedLocal: LocalExpectation
    let observedRemoteRevision: RemoteRevision?
}

struct UploadPlan: Hashable, Sendable {
    let expectedLocalHash: ContentHash
    let precondition: RemoteWritePrecondition
}

struct RemoveLocalPlan: Hashable, Sendable {
    let expectedLocalHash: ContentHash
}

enum ConflictReason: Hashable, Sendable {
    case localModifiedRemoteDeleted
    case localAndRemoteModified
    case remoteWriteCannotBeGuarded
    case remoteStateUnverifiable
    case untrackedBothPresent
}

enum UnsupportedReason: Hashable, Sendable {
    case localResource
    case remoteResource
    case localCreation
}

enum ConservativeRecoveryReason: Hashable, Sendable {
    case missingBaseline
}

enum SyncDecision: Hashable, Sendable {
    case noAction
    case download(DownloadPlan)
    case upload(UploadPlan)
    case removeLocal(RemoveLocalPlan)
    case establishBaseline(SyncBaselineState)
    case conflict(ConflictReason)
    case unsupported(UnsupportedReason)
    case needsConservativeRecovery(ConservativeRecoveryReason)
}

enum SyncPlanner {
    static func plan(
        context: SyncPlanningContext,
        local: LocalResourceState,
        remote: RemoteResourceState
    ) -> SyncDecision {
        if local == .unsupported {
            return .unsupported(.localResource)
        }
        if remote == .unsupported {
            return .unsupported(.remoteResource)
        }
        switch context {
        case .tracked(let baseline):
            return planTracked(baseline, local: local, remote: remote)
        case .initialImport:
            return planUntracked(local: local, remote: remote, isRecovery: false)
        case .conservativeRecovery:
            return planUntracked(local: local, remote: remote, isRecovery: true)
        }
    }

    private static func planTracked(
        _ baseline: SyncBaselineState,
        local: LocalResourceState,
        remote: RemoteResourceState
    ) -> SyncDecision {
        switch (local, remote) {
        case (.missing, .missing):
            return .noAction
        case (.missing, .present(let snapshot)):
            return download(.missing, snapshot: snapshot)
        case (.present(let localHash), .missing):
            return localHash == baseline.localHash
                ? .removeLocal(RemoveLocalPlan(expectedLocalHash: localHash))
                : .conflict(.localModifiedRemoteDeleted)
        case (.present(let localHash), .present(let snapshot)):
            return planBothPresent(
                baseline,
                localHash: localHash,
                remote: snapshot
            )
        default:
            return .unsupported(.localResource)
        }
    }

    private static func planBothPresent(
        _ baseline: SyncBaselineState,
        localHash: ContentHash,
        remote: RemoteSnapshot
    ) -> SyncDecision {
        let localChanged = localHash != baseline.localHash
        let remoteDelta = compare(remote.revision, with: baseline.remoteRevision)
        if remoteDelta == .unchanged,
            let verifiedHash = remote.verifiedContentHash,
            verifiedHash != baseline.localHash
        {
            return .conflict(.remoteStateUnverifiable)
        }
        switch remoteDelta {
        case .unchanged where !localChanged:
            return .noAction
        case .unchanged:
            guard let precondition = remote.writePrecondition else {
                return .conflict(.remoteWriteCannotBeGuarded)
            }
            return .upload(
                UploadPlan(
                    expectedLocalHash: localHash,
                    precondition: precondition
                )
            )
        case .changed where localChanged:
            return .conflict(.localAndRemoteModified)
        case .changed:
            return download(.matching(localHash), snapshot: remote)
        case .unknown where localChanged:
            return .conflict(.remoteStateUnverifiable)
        case .unknown:
            return download(.matching(localHash), snapshot: remote)
        }
    }

    private static func planUntracked(
        local: LocalResourceState,
        remote: RemoteResourceState,
        isRecovery: Bool
    ) -> SyncDecision {
        switch (local, remote) {
        case (.missing, .missing):
            return .noAction
        case (.missing, .present(let snapshot)):
            return download(.missing, snapshot: snapshot)
        case (.present, .missing):
            return isRecovery
                ? .needsConservativeRecovery(.missingBaseline)
                : .unsupported(.localCreation)
        case (.present(let hash), .present(let snapshot)):
            return planUntrackedPair(localHash: hash, remote: snapshot)
        default:
            return .unsupported(.localResource)
        }
    }

    private static func planUntrackedPair(
        localHash: ContentHash,
        remote: RemoteSnapshot
    ) -> SyncDecision {
        guard let remoteHash = remote.verifiedContentHash else {
            return .needsConservativeRecovery(.missingBaseline)
        }
        guard localHash == remoteHash else {
            return .conflict(.untrackedBothPresent)
        }
        return .establishBaseline(
            SyncBaselineState(
                localHash: localHash,
                remoteRevision: remote.revision
            )
        )
    }

    private static func download(
        _ expectation: LocalExpectation,
        snapshot: RemoteSnapshot
    ) -> SyncDecision {
        .download(
            DownloadPlan(
                expectedLocal: expectation,
                observedRemoteRevision: snapshot.revision
            )
        )
    }

    private static func compare(
        _ current: RemoteRevision?,
        with baseline: RemoteRevision?
    ) -> RemoteDelta {
        guard let current, let baseline else { return .unknown }
        return current == baseline ? .unchanged : .changed
    }
}

private enum RemoteDelta: Equatable {
    case unchanged
    case changed
    case unknown
}
