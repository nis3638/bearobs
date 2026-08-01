import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsDomain
#else
    @testable import BearObs
#endif

final class SyncPlannerTests: XCTestCase {
    func testPlansTrackedChangeMatrix() throws {
        let baseline = makeBaseline()
        let changedHash = hash("b")
        let unchangedRemote = remote(
            revision: baseline.remoteRevision,
            writeTag: "v1"
        )
        let unguardedRemote = remote(revision: baseline.remoteRevision)
        let changedRevision = revision("v2")
        let changedRemote = remote(revision: changedRevision)
        let unverifiableRemote = remote(revision: nil)
        let cases: [PlanCase] = [
            .init(.missing, .missing, .noAction),
            .init(.missing, unchangedRemote, download(.missing, revision("v1"))),
            .init(.missing, unguardedRemote, download(.missing, revision("v1"))),
            .init(.missing, changedRemote, download(.missing, changedRevision)),
            .init(.missing, unverifiableRemote, download(.missing, nil)),
            .init(.present(baseline.localHash), .missing, remove(baseline.localHash)),
            .init(.present(baseline.localHash), unchangedRemote, .noAction),
            .init(.present(baseline.localHash), unguardedRemote, .noAction),
            .init(
                .present(baseline.localHash),
                changedRemote,
                download(.matching(baseline.localHash), changedRevision)
            ),
            .init(
                .present(baseline.localHash),
                unverifiableRemote,
                download(.matching(baseline.localHash), nil)
            ),
            .init(
                .present(changedHash),
                .missing,
                .conflict(.localModifiedRemoteDeleted)
            ),
            .init(
                .present(changedHash),
                unchangedRemote,
                upload(changedHash, tag: "v1")
            ),
            .init(
                .present(changedHash),
                unguardedRemote,
                .conflict(.remoteWriteCannotBeGuarded)
            ),
            .init(
                .present(changedHash),
                changedRemote,
                .conflict(.localAndRemoteModified)
            ),
            .init(
                .present(changedHash),
                unverifiableRemote,
                .conflict(.remoteStateUnverifiable)
            ),
        ]

        XCTAssertEqual(cases.count, 15)
        for item in cases {
            XCTAssertEqual(
                SyncPlanner.plan(
                    context: .tracked(baseline),
                    local: item.local,
                    remote: item.remote
                ),
                item.expected,
                "\(item.local), \(item.remote)"
            )
        }
    }

    func testUnsupportedResourcesStopPlanning() {
        let baseline = makeBaseline()

        XCTAssertEqual(
            SyncPlanner.plan(
                context: .tracked(baseline),
                local: .unsupported,
                remote: .missing
            ),
            .unsupported(.localResource)
        )
        XCTAssertEqual(
            SyncPlanner.plan(
                context: .tracked(baseline),
                local: .missing,
                remote: .unsupported
            ),
            .unsupported(.remoteResource)
        )
    }

    func testUnverifiableRemoteNeverOverwritesChangedLocalContent() {
        let baseline = makeBaseline()
        let unverifiable = remote(revision: nil)

        XCTAssertEqual(
            SyncPlanner.plan(
                context: .tracked(baseline),
                local: .present(baseline.localHash),
                remote: unverifiable
            ),
            download(.matching(baseline.localHash), nil)
        )
        XCTAssertEqual(
            SyncPlanner.plan(
                context: .tracked(baseline),
                local: .present(hash("b")),
                remote: unverifiable
            ),
            .conflict(.remoteStateUnverifiable)
        )
    }

    func testUnchangedRevisionWithoutWriteGuardNeverUploads() throws {
        let revision = try RemoteRevision(
            reliableIdentifier: "certified-read-token-v1"
        )
        let baseline = makeBaseline(remoteRevision: revision)

        XCTAssertEqual(
            SyncPlanner.plan(
                context: .tracked(baseline),
                local: .present(hash("b")),
                remote: remote(revision: revision)
            ),
            .conflict(.remoteWriteCannotBeGuarded)
        )
    }

    func testCurrentSnapshotWriteGuardDoesNotPolluteRevisionIdentity() throws {
        let baselineRevision = try RemoteRevision(
            reliableIdentifier: "content-v1"
        )
        let baseline = makeBaseline(remoteRevision: baselineRevision)

        XCTAssertEqual(
            SyncPlanner.plan(
                context: .tracked(baseline),
                local: .present(hash("b")),
                remote: remote(
                    revision: baselineRevision,
                    writeTag: "guard-v2"
                )
            ),
            upload(hash("b"), tag: "guard-v2")
        )
    }

    func testContradictoryVerifiedHashNeverNoOpsOrUploads() {
        let baseline = makeBaseline()
        let contradictoryRemote = remote(
            revision: baseline.remoteRevision,
            verifiedHash: hash("c")
        )

        for localHash in [baseline.localHash, hash("b")] {
            XCTAssertEqual(
                SyncPlanner.plan(
                    context: .tracked(baseline),
                    local: .present(localHash),
                    remote: contradictoryRemote
                ),
                .conflict(.remoteStateUnverifiable)
            )
        }
    }

    func testInitialImportAndRecoveryDoNotShareNilBaseline() {
        let localHash = hash("a")
        let local = LocalResourceState.present(localHash)
        let matching = remote(
            revision: revision("v1"),
            verifiedHash: localHash
        )
        let different = remote(
            revision: revision("v1"),
            verifiedHash: hash("b")
        )
        let unknown = remote(revision: revision("v1"))

        XCTAssertEqual(
            SyncPlanner.plan(
                context: .initialImport,
                local: local,
                remote: .missing
            ),
            .unsupported(.localCreation)
        )
        XCTAssertEqual(
            SyncPlanner.plan(
                context: .conservativeRecovery,
                local: local,
                remote: .missing
            ),
            .needsConservativeRecovery(.missingBaseline)
        )
        for context in [
            SyncPlanningContext.initialImport,
            .conservativeRecovery,
        ] {
            XCTAssertEqual(
                SyncPlanner.plan(
                    context: context,
                    local: local,
                    remote: matching
                ),
                .establishBaseline(
                    SyncBaselineState(
                        localHash: localHash,
                        remoteRevision: revision("v1")
                    )
                )
            )
            XCTAssertEqual(
                SyncPlanner.plan(
                    context: context,
                    local: local,
                    remote: different
                ),
                .conflict(.untrackedBothPresent)
            )
            XCTAssertEqual(
                SyncPlanner.plan(
                    context: context,
                    local: local,
                    remote: unknown
                ),
                .needsConservativeRecovery(.missingBaseline)
            )
        }
    }

    func testPlansConservativeRecoveryMatrix() {
        let localHash = hash("a")
        let currentRevision = revision("v1")
        let unverifiedRemote = remote(revision: currentRevision)
        let verifiedRemote = remote(
            revision: currentRevision,
            verifiedHash: localHash
        )
        let established = SyncDecision.establishBaseline(
            SyncBaselineState(
                localHash: localHash,
                remoteRevision: currentRevision
            )
        )
        let cases: [PlanCase] = [
            .init(.missing, .missing, .noAction),
            .init(.missing, unverifiedRemote, download(.missing, currentRevision)),
            .init(.missing, verifiedRemote, download(.missing, currentRevision)),
            .init(.missing, .unsupported, .unsupported(.remoteResource)),
            .init(
                .present(localHash),
                .missing,
                .needsConservativeRecovery(.missingBaseline)
            ),
            .init(
                .present(localHash),
                unverifiedRemote,
                .needsConservativeRecovery(.missingBaseline)
            ),
            .init(.present(localHash), verifiedRemote, established),
            .init(
                .present(localHash),
                .unsupported,
                .unsupported(.remoteResource)
            ),
            .init(.unsupported, .missing, .unsupported(.localResource)),
            .init(.unsupported, unverifiedRemote, .unsupported(.localResource)),
            .init(.unsupported, verifiedRemote, .unsupported(.localResource)),
            .init(.unsupported, .unsupported, .unsupported(.localResource)),
        ]

        XCTAssertEqual(cases.count, 12)
        for item in cases {
            XCTAssertEqual(
                SyncPlanner.plan(
                    context: .conservativeRecovery,
                    local: item.local,
                    remote: item.remote
                ),
                item.expected,
                "\(item.local), \(item.remote)"
            )
        }
    }

    func testContentHashAndStrongETagRejectInvalidValues() {
        XCTAssertThrowsError(try ContentHash(hex: "abc"))
        XCTAssertThrowsError(try ContentHash(hex: String(repeating: "g", count: 64)))
        XCTAssertEqual(
            try StrongETag(headerValue: "\"\"").headerValue,
            "\"\""
        )
        XCTAssertEqual(
            try StrongETag(headerValue: "\"W/foo\"").headerValue,
            "\"W/foo\""
        )
        XCTAssertEqual(
            RemoteWritePrecondition.ifMatch(
                try StrongETag(headerValue: "\"*\"")
            ).headerValue,
            "\"*\""
        )
        for invalid in [
            "v1",
            "W/\"weak\"",
            "\"one\", \"two\"",
            "*",
            "\"bad\r\ntag\"",
            "\"bad tag\"",
            "\"bad\\\"tag\"",
            "\"emoji-😀\"",
        ] {
            XCTAssertThrowsError(
                try StrongETag(headerValue: invalid),
                "accepted invalid strong ETag: \(invalid)"
            )
        }
    }

    func testValidatedIdentifiersRoundTripThroughCodable() throws {
        let contentHash = try ContentHash(
            hex: String(repeating: "A", count: 64)
        )
        let tag = try StrongETag(headerValue: "\"v1\"")
        let revision = RemoteRevision(strongETag: tag)

        XCTAssertEqual(contentHash.hex, String(repeating: "a", count: 64))
        XCTAssertEqual(
            try roundTrip(contentHash, as: ContentHash.self),
            contentHash
        )
        XCTAssertEqual(try roundTrip(tag, as: StrongETag.self), tag)
        XCTAssertEqual(
            try roundTrip(revision, as: RemoteRevision.self),
            revision
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ContentHash.self,
                from: Data("\"invalid\"".utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                StrongETag.self,
                from: Data("\"W/\\\"weak\\\"\"".utf8)
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                RemoteRevision.self,
                from: Data("{\"reliableIdentifier\":\"\"}".utf8)
            )
        )
        XCTAssertThrowsError(
            try RemoteRevision(
                reliableIdentifier: "bad\nidentifier"
            )
        )
    }

    private func makeBaseline(
        remoteRevision: RemoteRevision? = nil
    ) -> SyncBaselineState {
        SyncBaselineState(
            localHash: hash("a"),
            remoteRevision: remoteRevision ?? revision("v1")
        )
    }

    private func remote(
        revision: RemoteRevision?,
        writeTag: String? = nil,
        verifiedHash: ContentHash? = nil
    ) -> RemoteResourceState {
        .present(
            RemoteSnapshot(
                revision: revision,
                writePrecondition: writeTag.map {
                    .ifMatch(strongTag($0))
                },
                verifiedContentHash: verifiedHash
            )
        )
    }

    private func revision(_ value: String) -> RemoteRevision {
        let tag = strongTag(value)
        return RemoteRevision(strongETag: tag)
    }

    private func strongTag(_ opaqueValue: String) -> StrongETag {
        try! StrongETag(headerValue: "\"\(opaqueValue)\"")
    }

    private func download(
        _ local: LocalExpectation,
        _ revision: RemoteRevision?
    ) -> SyncDecision {
        .download(
            DownloadPlan(
                expectedLocal: local,
                observedRemoteRevision: revision
            )
        )
    }

    private func upload(_ localHash: ContentHash, tag: String) -> SyncDecision {
        .upload(
            UploadPlan(
                expectedLocalHash: localHash,
                precondition: .ifMatch(strongTag(tag))
            )
        )
    }

    private func remove(_ hash: ContentHash) -> SyncDecision {
        .removeLocal(RemoveLocalPlan(expectedLocalHash: hash))
    }

    private func hash(_ character: Character) -> ContentHash {
        try! ContentHash(hex: String(repeating: character, count: 64))
    }

    private func roundTrip<Value: Codable & Equatable>(
        _ value: Value,
        as type: Value.Type
    ) throws -> Value {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}

private struct PlanCase {
    let local: LocalResourceState
    let remote: RemoteResourceState
    let expected: SyncDecision

    init(
        _ local: LocalResourceState,
        _ remote: RemoteResourceState,
        _ expected: SyncDecision
    ) {
        self.local = local
        self.remote = remote
        self.expected = expected
    }
}
