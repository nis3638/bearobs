import Foundation
import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class VerifierStateMachineTests: XCTestCase {
    func testDedicatedDirectoryHTTPFailuresIdentifyDepthAndPerformZeroWrites() async throws {
        for (depth, status) in [(0, 401), (1, 404)] {
            let journal = FakeJournal()
            defer { journal.removeTemporaryDirectory() }
            let fixture = FakeVerifierRemote(
                mode: .dedicatedDirectoryStatus(depth: depth, status: status),
                journal: journal
            )
            let verifier = makeVerifier(remote: fixture, journal: journal)

            let error = await thrownError { try await verifier.verify() }

            XCTAssertEqual(
                error as? VerifierFailure,
                .dedicatedDirectoryHTTPStatus(depth: depth, status: status)
            )
            let operations = await fixture.operations
            XCTAssertFalse(operations.contains(where: \.isMutation))
        }
    }

    func testNonEmptyDedicatedDirectoryPerformsZeroWrites() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .nonEmpty, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .dedicatedDirectoryNotEmpty)
        let operations = await fixture.operations
        XCTAssertFalse(operations.contains(where: \.isMutation))
    }

    func testFileCreationCollisionNeverTriggersAutomaticDelete() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .fileCreationCollision, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        XCTAssertEqual(try journal.recovery.load()?.state, .manualReview)
        let operations = await fixture.operations
        XCTAssertTrue(operations.contains { $0.kind == .put && $0.resultStatus == 204 })
        XCTAssertFalse(operations.contains { $0.kind == .delete })
    }

    func testManualReviewJournalStopsBeforeAnyRemoteMutation() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-manual-review")
        try journal.recovery.start(
            runDirectory: run,
            scopeIdentifier: verifierTestScopeIdentifier
        )
        try journal.recovery.markManualReview()
        let fixture = FakeVerifierRemote(mode: .success, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        XCTAssertEqual(try journal.recovery.load()?.state, .manualReview)
        let operations = await fixture.operations
        XCTAssertFalse(operations.contains(where: \.isMutation))
    }

    func testRecoveryScopeMismatchMarksManualReviewBeforeAnyRemoteRequest() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-old-run")
        try journal.recovery.start(
            runDirectory: run,
            scopeIdentifier: "different-origin|different-root|different-account"
        )
        let fixture = FakeVerifierRemote(mode: .success, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        XCTAssertEqual(try journal.recovery.load()?.state, .manualReview)
        let operations = await fixture.operations
        XCTAssertTrue(operations.isEmpty)
    }

    func testFullRunProvesStaleETagPreservesBodyAndCleansExactJournalAllowlist() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .success, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let report = try await verifier.verify()

        XCTAssertEqual(
            report.results.first { $0.capability == .staleETagPrecondition },
            CapabilityResult(
                capability: .staleETagPrecondition,
                status: .pass,
                httpStatus: 412,
                reason: nil,
                evidence: []
            )
        )
        XCTAssertEqual(
            report.results.first { $0.capability == .staleWritePreservesBody },
            CapabilityResult(
                capability: .staleWritePreservesBody,
                status: .pass,
                httpStatus: nil,
                reason: nil,
                evidence: [.bodyUnchanged]
            )
        )
        XCTAssertEqual(
            report.results.first { $0.capability == .staleDeletePrecondition },
            CapabilityResult(
                capability: .staleDeletePrecondition,
                status: .pass,
                httpStatus: 412,
                reason: nil,
                evidence: [.bodyUnchanged]
            )
        )
        XCTAssertEqual(
            report.results.first { $0.capability == .paginationBeyond750 },
            CapabilityResult(
                capability: .paginationBeyond750,
                status: .blocked,
                httpStatus: nil,
                reason: .vendorPaginationProtocolUndocumented,
                evidence: []
            )
        )
        XCTAssertNil(try journal.recovery.load())

        let operations = await fixture.operations
        try assertSuccessfulETagExchange(in: operations)
        let firstDelete = try XCTUnwrap(operations.first(where: { $0.kind == .delete }))
        let record = try XCTUnwrap(firstDelete.journal.record)
        let expectedDeletes = try decodedAllowlist(from: record)
        let deletedPaths: [String] = operations.compactMap { operation in
            guard operation.kind == .delete,
                operation.resultStatus.map({ (200...299).contains($0) }) == true,
                let path = operation.path
            else {
                return nil
            }
            return path
        }
        XCTAssertEqual(Set(deletedPaths), expectedDeletes)
        XCTAssertEqual(deletedPaths.count, expectedDeletes.count)
    }

    func testStaleDeletePreconditionMustReturn412AndPreserveTheSyntheticFile() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(
            mode: .ignoreStaleDeletePrecondition,
            journal: journal
        )
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .staleDeleteWasAccepted)
        let operations = await fixture.operations
        let staleDelete = try XCTUnwrap(
            operations.first { operation in
                operation.kind == .delete
                    && operation.ifMatch == "\"v1\""
            }
        )
        XCTAssertEqual(staleDelete.resultStatus, 204)
    }

    func testCorruptRecoveryJournalRequiresManualReviewBeforeAnyRemoteRequest() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        try journal.corruptRecord()
        let fixture = FakeVerifierRemote(mode: .success, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        let operations = await fixture.operations
        XCTAssertTrue(operations.isEmpty)
    }

    func testInsecureRecoveryDirectoryRequiresManualReviewBeforeLeaseOrRemoteRequest() async throws
    {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        try journal.makeRecoveryDirectoryInsecure()
        let fixture = FakeVerifierRemote(mode: .success, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        let operations = await fixture.operations
        XCTAssertTrue(operations.isEmpty)
    }

    func testFailedCreationProvesMissingIntentAndClearsJournalWithoutDelete() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .failOnceDuringSpecialPath, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .remoteOperationFailed)
        let operations = await fixture.operations
        let failedPut = try XCTUnwrap(
            operations.first { $0.kind == .put && $0.resultStatus == nil }
        )
        let path = try XCTUnwrap(failedPut.path)
        XCTAssertTrue(
            operations.contains {
                $0.kind == .get && $0.path == path && $0.resultStatus == 404
            }
        )
        XCTAssertFalse(operations.contains { $0.kind == .delete })
        XCTAssertNil(try journal.recovery.load())
    }

    func testRecoveryHashMismatchFailsClosedAndMarksManualReview() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-old-run")
        let file = try VerifierPath(decodedRelativePath: "bearobs-m0-11-old-run/note.md")
        try journal.recovery.start(
            runDirectory: run,
            scopeIdentifier: verifierTestScopeIdentifier
        )
        try journal.recovery.registerIntent(
            path: file,
            kind: .file,
            expectedBodies: [Data("expected".utf8)],
            etag: nil
        )
        let fixture = FakeVerifierRemote(
            mode: .success,
            initialResources: [
                .collection(run),
                .file(file, body: Data("different".utf8), etag: "\"foreign\""),
            ],
            journal: journal
        )
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        XCTAssertEqual(try journal.recovery.load()?.state, .manualReview)
        let operations = await fixture.operations
        XCTAssertFalse(operations.contains(where: \.isMutation))
    }

    func testRecoveryNeverDeletesBeforeConditionalDeleteWasProven() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-unproven-run.md")
        let body = Data("owned-but-delete-semantics-unproven".utf8)
        try journal.recovery.start(
            runDirectory: run,
            scopeIdentifier: verifierTestScopeIdentifier
        )
        try journal.recovery.registerIntent(
            path: run,
            kind: .file,
            expectedBodies: [body],
            etag: nil
        )
        let fixture = FakeVerifierRemote(
            mode: .success,
            initialResources: [.file(run, body: body, etag: "\"owned\"")],
            journal: journal
        )
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        XCTAssertEqual(try journal.recovery.load()?.state, .manualReview)
        let operations = await fixture.operations
        XCTAssertFalse(operations.contains { $0.kind == .delete })
    }

    func testRecoveryProvesEntireAllowlistBeforeFirstDelete() async throws {
        let (journal, scenario, fixture, verifier) = try makeRecoveryVerifier()
        defer { journal.removeTemporaryDirectory() }

        _ = await thrownError { try await verifier.verify() }

        let operations = await fixture.operations
        let record = try XCTUnwrap(
            operations.first(where: { $0.kind == .delete })?.journal.record
        )
        try assertEveryJournalResourceWasProven(
            record: record,
            beforeFirstDeleteIn: operations
        )
        XCTAssertEqual(record.runDirectory, scenario.run.percentEncodedRelativePath)
    }

    func testRecoveryDeletesExactlyCanonicalJournalAllowlist() async throws {
        let (journal, scenario, fixture, verifier) = try makeRecoveryVerifier()
        defer { journal.removeTemporaryDirectory() }

        _ = await thrownError { try await verifier.verify() }

        let deletedPaths = await fixture.deletedPaths
        XCTAssertEqual(Set(deletedPaths), Set(scenario.allowedDecodedPaths))
        XCTAssertEqual(deletedPaths.count, scenario.allowedDecodedPaths.count)
        XCTAssertNil(try journal.recovery.load())
    }

    func testRecoveryUsesConditionalDeleteForEveryFile() async throws {
        let (journal, scenario, fixture, verifier) = try makeRecoveryVerifier()
        defer { journal.removeTemporaryDirectory() }

        _ = await thrownError { try await verifier.verify() }

        let operations = await fixture.operations
        let deletes = operations.filter { $0.kind == .delete }
        XCTAssertEqual(deletes.count, scenario.files.count)
        XCTAssertTrue(deletes.allSatisfy { $0.ifMatch != nil })
    }

    func testEveryDeleteIsImmediatelyFollowedByA404Confirmation() async throws {
        let (journal, _, fixture, verifier) = try makeRecoveryVerifier()
        defer { journal.removeTemporaryDirectory() }

        _ = await thrownError { try await verifier.verify() }

        let operations = await fixture.operations
        let deleteIndices = operations.indices.filter { operations[$0].kind == .delete }
        XCTAssertFalse(deleteIndices.isEmpty)
        for deleteIndex in deleteIndices {
            let delete = operations[deleteIndex]
            let confirmationIndex = operations.index(after: deleteIndex)
            XCTAssertLessThan(confirmationIndex, operations.endIndex)
            guard confirmationIndex < operations.endIndex else { continue }
            let confirmation = operations[confirmationIndex]
            XCTAssertEqual(confirmation.path, delete.path)
            XCTAssertTrue(confirmation.kind == .get || confirmation.kind == .list)
            XCTAssertEqual(confirmation.resultStatus, 404)
        }
    }

    func testDeleteSuccessButResourceStillExistsThrowsCleanupFailedAndKeepsJournal() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let scenario = try RecoveryScenario.make()
        try scenario.seed(journal.recovery)
        let fixture = FakeVerifierRemote(
            mode: .deleteReportsSuccessButKeepsResource,
            initialResources: scenario.remoteResources,
            journal: journal,
            unauthenticatedStatus: 500
        )
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .cleanupFailed)
        XCTAssertEqual(try journal.recovery.load()?.state, .cleanupAuthorized)
        let operations = await fixture.operations
        let deleteIndex = try XCTUnwrap(
            operations.firstIndex(where: { $0.kind == .delete })
        )
        XCTAssertEqual(operations[deleteIndex].resultStatus, 204)
        let confirmationIndex = operations.index(after: deleteIndex)
        XCTAssertLessThan(confirmationIndex, operations.endIndex)
        guard confirmationIndex < operations.endIndex else { return }
        XCTAssertEqual(operations[confirmationIndex].path, operations[deleteIndex].path)
        XCTAssertNotEqual(operations[confirmationIndex].resultStatus, 404)
    }

    func testFileReplacementAfterProofFailsConditionalDeleteAndKeepsJournal() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let scenario = try RecoveryScenario.make()
        try scenario.seed(journal.recovery)
        let fixture = FakeVerifierRemote(
            mode: .replaceFileBeforeDelete,
            initialResources: scenario.remoteResources,
            journal: journal,
            unauthenticatedStatus: 500
        )
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .cleanupFailed)
        XCTAssertEqual(try journal.recovery.load()?.state, .cleanupAuthorized)
        let operations = await fixture.operations
        let firstDelete = try XCTUnwrap(operations.first { $0.kind == .delete })
        XCTAssertNotNil(firstDelete.ifMatch)
        XCTAssertEqual(firstDelete.resultStatus, 412)
    }

    func testRecoveryCollectionRequiresManualReviewWithoutDeletion() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-old-run")
        let collection = try VerifierPath(decodedRelativePath: run.description + "/nested")
        let foreign = try VerifierPath(
            decodedRelativePath: collection.description + "/foreign.bin"
        )
        try journal.recovery.start(
            runDirectory: run,
            scopeIdentifier: verifierTestScopeIdentifier
        )
        try journal.recovery.registerIntent(
            path: collection,
            kind: .collection,
            expectedBodies: [],
            etag: try StrongETag(headerValue: "\"collection\"")
        )
        let fixture = FakeVerifierRemote(
            mode: .success,
            initialResources: [
                .collection(collection),
                .file(foreign, body: Data("not-owned".utf8), etag: "\"foreign\""),
            ],
            journal: journal,
            unauthenticatedStatus: 500
        )
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .manualReviewRequired)
        XCTAssertEqual(try journal.recovery.load()?.state, .manualReview)
        let operations = await fixture.operations
        XCTAssertFalse(operations.contains(where: \.isMutation))
    }

    func testJournalStartAndResourceIntentExistBeforeEveryMKCOLAndPUT() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .success, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        _ = try await verifier.verify()

        let operations = await fixture.operations
        let creationOperations = operations.filter {
            $0.kind == .makeCollection || $0.kind == .put
        }
        XCTAssertFalse(creationOperations.isEmpty)
        XCTAssertTrue(
            creationOperations.contains { operation in
                operation.kind == .put
                    && operation.path?.contains("unicode-中文 space %.md") == true
            }
        )

        for operation in creationOperations {
            let record = try XCTUnwrap(operation.journal.record)
            XCTAssertNotEqual(record.state, .manualReview)
            if operation.kind == .put, operation.ifMatch == nil {
                XCTAssertEqual(record.state, .cleanupPending)
            }
            let path = try XCTUnwrap(operation.path)
            let encodedPath = try VerifierPath(
                decodedRelativePath: path
            ).percentEncodedRelativePath

            switch operation.kind {
            case .makeCollection where encodedPath == record.runDirectory:
                break  // start(runDirectory:) is the root MKCOL intent.
            case .makeCollection:
                let resource = record.resources.first { $0.path == encodedPath }
                XCTAssertEqual(resource?.kind, .collection)
            case .put:
                let body = try XCTUnwrap(operation.requestBody)
                let resource = record.resources.first { $0.path == encodedPath }
                XCTAssertEqual(resource?.kind, .file)
                XCTAssertEqual(resource?.matchesExpectedBody(body), true)
            default:
                XCTFail("unexpected creation operation")
            }
        }
    }

    func testEqualE1AndE2FailsBeforeAttemptingTheStaleWrite() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .unchangedETagAfterUpdate, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertNotNil(error as? VerifierFailure)
        let operations = await fixture.operations
        let exchange = try XCTUnwrap(mostFrequentlyWrittenPath(in: operations))
        let putIndices = indices(of: .put, path: exchange, in: operations)
        XCTAssertEqual(putIndices.count, 2, "stale PUT must not run when E2 == E1")
        guard putIndices.count == 2 else { return }
        let baselineRead = try XCTUnwrap(
            firstOperation(
                of: .get, path: exchange, after: putIndices[0], before: putIndices[1],
                in: operations)
        )
        let updatedRead = try XCTUnwrap(
            firstOperation(of: .get, path: exchange, after: putIndices[1], in: operations)
        )
        XCTAssertEqual(baselineRead.responseETag, updatedRead.responseETag)
    }

    func testStalePUTReturningAnythingOtherThan412FailsVerification() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .staleWriteStatus(409), journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertNotNil(error as? VerifierFailure)
        let operations = await fixture.operations
        let exchange = try XCTUnwrap(mostFrequentlyWrittenPath(in: operations))
        let puts = indices(of: .put, path: exchange, in: operations).map { operations[$0] }
        XCTAssertEqual(puts.count, 3)
        XCTAssertEqual(puts.last?.resultStatus, 409)
    }

    func testStale412ThatChangesBodyThrowsStaleWriteChangedBody() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(
            mode: .staleWriteChangesBodyDespite412,
            journal: journal
        )
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .staleWriteChangedBody)
        let operations = await fixture.operations
        let exchange = try XCTUnwrap(mostFrequentlyWrittenPath(in: operations))
        let putIndices = indices(of: .put, path: exchange, in: operations)
        XCTAssertEqual(putIndices.count, 3)
        guard let staleIndex = putIndices.last else { return }
        XCTAssertEqual(operations[staleIndex].resultStatus, 412)
        let readAfterStale = try XCTUnwrap(
            firstOperation(of: .get, path: exchange, after: staleIndex, in: operations)
        )
        XCTAssertEqual(readAfterStale.responseBody, operations[staleIndex].requestBody)
    }

    func testUnknownRemoteErrorMapsToRemoteOperationFailed() async throws {
        let journal = FakeJournal()
        defer { journal.removeTemporaryDirectory() }
        let fixture = FakeVerifierRemote(mode: .unknownFailureAtProbe, journal: journal)
        let verifier = makeVerifier(remote: fixture, journal: journal)

        let error = await thrownError { try await verifier.verify() }

        XCTAssertEqual(error as? VerifierFailure, .remoteOperationFailed)
        let operations = await fixture.operations
        XCTAssertEqual(operations.map(\.kind), [.unauthenticatedProbe])
        XCTAssertFalse(operations.contains(where: \.isMutation))
    }

    private func makeVerifier(
        remote: FakeVerifierRemote,
        journal: FakeJournal,
        runComponent: String = "bearobs-m0-11-test-run",
        scopeIdentifier: String = verifierTestScopeIdentifier
    ) -> JianguoyunVerifier {
        JianguoyunVerifier(
            remote: remote,
            journal: journal.recovery,
            runComponent: runComponent,
            scopeIdentifier: scopeIdentifier
        )
    }

    private func makeRecoveryVerifier() throws -> (
        FakeJournal,
        RecoveryScenario,
        FakeVerifierRemote,
        JianguoyunVerifier
    ) {
        let journal = FakeJournal()
        let scenario = try RecoveryScenario.make()
        try scenario.seed(journal.recovery)
        let fixture = FakeVerifierRemote(
            mode: .success,
            initialResources: scenario.remoteResources,
            journal: journal,
            unauthenticatedStatus: 500
        )
        return (journal, scenario, fixture, makeVerifier(remote: fixture, journal: journal))
    }

    private func assertSuccessfulETagExchange(
        in operations: [FakeOperation],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let path = try XCTUnwrap(
            mostFrequentlyWrittenPath(in: operations),
            file: file,
            line: line
        )
        let putIndices = indices(of: .put, path: path, in: operations)
        XCTAssertEqual(putIndices.count, 3, file: file, line: line)
        guard putIndices.count == 3 else { return }

        let baselineRead = try XCTUnwrap(
            firstOperation(
                of: .get,
                path: path,
                after: putIndices[0],
                before: putIndices[1],
                in: operations
            ),
            file: file,
            line: line
        )
        let updatedRead = try XCTUnwrap(
            firstOperation(
                of: .get,
                path: path,
                after: putIndices[1],
                before: putIndices[2],
                in: operations
            ),
            file: file,
            line: line
        )
        let readAfterStale = try XCTUnwrap(
            firstOperation(of: .get, path: path, after: putIndices[2], in: operations),
            file: file,
            line: line
        )
        let e1 = try XCTUnwrap(baselineRead.responseETag, file: file, line: line)
        let e2 = try XCTUnwrap(updatedRead.responseETag, file: file, line: line)

        XCTAssertNotEqual(e1, e2, file: file, line: line)
        XCTAssertEqual(operations[putIndices[1]].ifMatch, e1, file: file, line: line)
        XCTAssertEqual(operations[putIndices[2]].ifMatch, e1, file: file, line: line)
        XCTAssertEqual(operations[putIndices[2]].resultStatus, 412, file: file, line: line)
        XCTAssertEqual(
            readAfterStale.responseBody,
            operations[putIndices[1]].requestBody,
            file: file,
            line: line
        )
    }

    private func assertEveryJournalResourceWasProven(
        record: RecoveryRecord,
        beforeFirstDeleteIn operations: [FakeOperation],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let firstDelete = try XCTUnwrap(
            operations.firstIndex(where: { $0.kind == .delete }),
            file: file,
            line: line
        )
        for resource in record.resources {
            let path = try VerifierPath(
                percentEncodedRelativePath: resource.path
            ).description
            let wasProven = operations[..<firstDelete].contains { operation in
                guard operation.path == path else { return false }
                switch resource.kind {
                case .file:
                    return operation.kind == .get
                        && (operation.resultStatus == 200 || operation.resultStatus == 404)
                case .collection:
                    return operation.kind == .list
                        && operation.depth == 1
                        && (operation.resultStatus == 207 || operation.resultStatus == 404)
                }
            }
            XCTAssertTrue(
                wasProven,
                "resource was not proven before the first DELETE",
                file: file,
                line: line
            )
        }
    }
}

private final class FakeJournal: @unchecked Sendable {
    let recovery: RecoveryJournal
    private let directory: URL
    private let fileURL: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        fileURL = directory.appendingPathComponent("recovery.json")
        recovery = RecoveryJournal(fileURL: fileURL)
    }

    func corruptRecord() throws {
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-corrupt-run")
        try recovery.start(
            runDirectory: run,
            scopeIdentifier: verifierTestScopeIdentifier
        )
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("{".utf8))
        try handle.synchronize()
    }

    func makeRecoveryDirectoryInsecure() throws {
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-insecure-run")
        try recovery.start(
            runDirectory: run,
            scopeIdentifier: verifierTestScopeIdentifier
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: directory.path
        )
    }

    func snapshot() -> JournalObservation {
        do {
            return JournalObservation(record: try recovery.load(), loadFailed: false)
        } catch {
            return JournalObservation(record: nil, loadFailed: true)
        }
    }

    func removeTemporaryDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct JournalObservation: Sendable {
    let record: RecoveryRecord?
    let loadFailed: Bool

    static let unavailable = JournalObservation(record: nil, loadFailed: false)
}

private struct FakeOperation: Sendable {
    enum Kind: Sendable, Equatable {
        case unauthenticatedProbe
        case list
        case makeCollection
        case put
        case get
        case delete
    }

    let kind: Kind
    let path: String?
    let depth: Int?
    let requestBody: Data?
    let ifMatch: String?
    let resultStatus: Int?
    let responseBody: Data?
    let responseETag: String?
    let journal: JournalObservation

    var isMutation: Bool {
        kind == .makeCollection || kind == .put || kind == .delete
    }
}

private enum FakeTransportError: Error, Sendable {
    case injected
}

private struct RemoteResourceFixture: Sendable {
    let path: VerifierPath
    let body: Data
    let etag: String?
    let isCollection: Bool

    static func collection(_ path: VerifierPath) -> Self {
        Self(
            path: path,
            body: Data(),
            etag: "\"collection-\(path.percentEncodedRelativePath)\"",
            isCollection: true
        )
    }

    static func file(_ path: VerifierPath, body: Data, etag: String) -> Self {
        Self(path: path, body: body, etag: etag, isCollection: false)
    }
}

private actor FakeVerifierRemote: VerifierRemote {
    enum Mode: Sendable {
        case dedicatedDirectoryStatus(depth: Int, status: Int)
        case nonEmpty
        case success
        case failOnceDuringSpecialPath
        case deleteReportsSuccessButKeepsResource
        case replaceFileBeforeDelete
        case fileCreationCollision
        case unchangedETagAfterUpdate
        case staleWriteStatus(Int)
        case staleWriteChangesBodyDespite412
        case ignoreStaleDeletePrecondition
        case unknownFailureAtProbe
    }

    private struct Resource: Sendable {
        var body: Data
        var etag: String?
        let isCollection: Bool
    }

    private let mode: Mode
    private let journal: FakeJournal?
    private let unauthenticatedStatus: Int
    private(set) var operations: [FakeOperation] = []
    private(set) var deletedPaths: [String] = []
    private var resources: [String: Resource] = [:]
    private var didInjectFailure = false

    init(
        mode: Mode,
        initialResources: [RemoteResourceFixture] = [],
        journal: FakeJournal? = nil,
        unauthenticatedStatus: Int = 401
    ) {
        self.mode = mode
        self.journal = journal
        self.unauthenticatedStatus = unauthenticatedStatus
        for fixture in initialResources {
            resources[fixture.path.description] = Resource(
                body: fixture.body,
                etag: fixture.etag,
                isCollection: fixture.isCollection
            )
        }
        if case .nonEmpty = mode {
            resources["preexisting.md"] = Resource(
                body: Data("existing".utf8),
                etag: "\"existing\"",
                isCollection: false
            )
        }
    }

    func unauthenticatedDepthZeroStatus() async throws -> Int {
        let observation = observeJournal()
        if case .unknownFailureAtProbe = mode {
            record(.unauthenticatedProbe, resultStatus: nil, journal: observation)
            throw FakeTransportError.injected
        }
        record(
            .unauthenticatedProbe,
            resultStatus: unauthenticatedStatus,
            journal: observation
        )
        return unauthenticatedStatus
    }

    func list(path: VerifierPath?, depth: Int) async throws -> RemoteListing {
        let observation = observeJournal()
        let listing: RemoteListing
        if case .dedicatedDirectoryStatus(let injectedDepth, let status) = mode,
            path == nil,
            depth == injectedDepth
        {
            listing = RemoteListing(statusCode: status, entries: [])
        } else if path == nil {
            var entries = [RemoteEntry(path: nil, isCollection: true, etagHeader: nil)]
            if depth == 1 {
                entries += resources.keys.sorted().compactMap { key in
                    guard !key.contains("/"),
                        let child = try? VerifierPath(decodedRelativePath: key),
                        let resource = resources[key]
                    else {
                        return nil
                    }
                    return RemoteEntry(
                        path: child,
                        isCollection: resource.isCollection,
                        etagHeader: resource.etag
                    )
                }
            }
            listing = RemoteListing(statusCode: 207, entries: entries)
        } else if let path, let resource = resources[path.description] {
            var entries = [
                RemoteEntry(
                    path: path,
                    isCollection: resource.isCollection,
                    etagHeader: resource.etag
                )
            ]
            if resource.isCollection && depth == 1 {
                let prefix = path.description + "/"
                entries += resources.keys.sorted().compactMap { key in
                    guard key.hasPrefix(prefix),
                        !key.dropFirst(prefix.count).contains("/"),
                        let child = try? VerifierPath(decodedRelativePath: key),
                        let childResource = resources[key]
                    else {
                        return nil
                    }
                    return RemoteEntry(
                        path: child,
                        isCollection: childResource.isCollection,
                        etagHeader: childResource.etag
                    )
                }
            }
            listing = RemoteListing(statusCode: 207, entries: entries)
        } else {
            listing = RemoteListing(statusCode: 404, entries: [])
        }
        record(
            .list,
            path: path?.description,
            depth: depth,
            resultStatus: listing.statusCode,
            journal: observation
        )
        return listing
    }

    func makeCollection(path: VerifierPath) async throws -> Int {
        let observation = observeJournal()
        let key = path.description
        let status: Int
        if resources[key] != nil {
            status = 405
        } else if let parent = parentPath(of: key), resources[parent]?.isCollection != true {
            status = 409
        } else {
            resources[key] = Resource(
                body: Data(),
                etag: "\"collection-created\"",
                isCollection: true
            )
            status = 201
        }
        record(
            .makeCollection,
            path: key,
            resultStatus: status,
            journal: observation
        )
        return status
    }

    func put(path: VerifierPath, body: Data, ifMatch: StrongETag?) async throws -> Int {
        let observation = observeJournal()
        let key = path.description
        if case .fileCreationCollision = mode, ifMatch == nil {
            resources[key] = Resource(body: body, etag: "\"v1\"", isCollection: false)
            record(
                .put,
                path: key,
                requestBody: body,
                ifMatch: nil,
                resultStatus: 204,
                journal: observation
            )
            return 204
        }
        if case .failOnceDuringSpecialPath = mode,
            key.contains("unicode-中文 space %.md"),
            !didInjectFailure
        {
            didInjectFailure = true
            record(
                .put,
                path: key,
                requestBody: body,
                ifMatch: ifMatch?.headerValue,
                resultStatus: nil,
                journal: observation
            )
            throw VerifierFailure.remoteOperationFailed
        }

        let status: Int
        if let parent = parentPath(of: key), resources[parent]?.isCollection != true {
            status = 409
        } else if let ifMatch {
            guard var current = resources[key], !current.isCollection else {
                record(
                    .put,
                    path: key,
                    requestBody: body,
                    ifMatch: ifMatch.headerValue,
                    resultStatus: 412,
                    journal: observation
                )
                return 412
            }
            if current.etag == ifMatch.headerValue {
                current.body = body
                if case .unchangedETagAfterUpdate = mode {
                    // Intentionally retain E1.
                } else {
                    current.etag = "\"v2\""
                }
                resources[key] = current
                status = 204
            } else {
                switch mode {
                case .staleWriteStatus(let injectedStatus):
                    status = injectedStatus
                case .staleWriteChangesBodyDespite412:
                    current.body = body
                    current.etag = "\"v3\""
                    resources[key] = current
                    status = 412
                default:
                    status = 412
                }
            }
        } else {
            let existed = resources[key] != nil
            resources[key] = Resource(body: body, etag: "\"v1\"", isCollection: false)
            status = existed ? 204 : 201
        }

        record(
            .put,
            path: key,
            requestBody: body,
            ifMatch: ifMatch?.headerValue,
            resultStatus: status,
            journal: observation
        )
        return status
    }

    func get(path: VerifierPath) async throws -> RemoteRead {
        let observation = observeJournal()
        let read: RemoteRead
        if let resource = resources[path.description], !resource.isCollection {
            read = RemoteRead(
                statusCode: 200,
                body: resource.body,
                etagHeader: resource.etag
            )
        } else {
            read = RemoteRead(statusCode: 404, body: Data(), etagHeader: nil)
        }
        record(
            .get,
            path: path.description,
            resultStatus: read.statusCode,
            responseBody: read.body,
            responseETag: read.etagHeader,
            journal: observation
        )
        return read
    }

    func delete(path: VerifierPath, ifMatch: StrongETag?) async throws -> Int {
        let observation = observeJournal()
        let key = path.description
        deletedPaths.append(key)
        let status: Int
        guard let resource = resources[key] else {
            status = 404
            record(
                .delete,
                path: key,
                ifMatch: ifMatch?.headerValue,
                resultStatus: status,
                journal: observation
            )
            return status
        }
        if case .replaceFileBeforeDelete = mode, !resource.isCollection, !didInjectFailure {
            didInjectFailure = true
            resources[key] = Resource(
                body: Data("foreign-replacement".utf8),
                etag: "\"foreign-replacement\"",
                isCollection: false
            )
        }
        if let ifMatch, resources[key]?.etag != ifMatch.headerValue {
            if case .ignoreStaleDeletePrecondition = mode {
                resources[key] = nil
                status = 204
                record(
                    .delete,
                    path: key,
                    ifMatch: ifMatch.headerValue,
                    resultStatus: status,
                    journal: observation
                )
                return status
            }
            status = 412
            record(
                .delete,
                path: key,
                ifMatch: ifMatch.headerValue,
                resultStatus: status,
                journal: observation
            )
            return status
        }
        if resource.isCollection {
            let prefix = key + "/"
            if resources.keys.contains(where: { $0.hasPrefix(prefix) }) {
                status = 409
                record(
                    .delete,
                    path: key,
                    ifMatch: ifMatch?.headerValue,
                    resultStatus: status,
                    journal: observation
                )
                return status
            }
        }
        if case .deleteReportsSuccessButKeepsResource = mode {
            status = 204
        } else {
            resources[key] = nil
            status = 204
        }
        record(
            .delete,
            path: key,
            ifMatch: ifMatch?.headerValue,
            resultStatus: status,
            journal: observation
        )
        return status
    }

    private func observeJournal() -> JournalObservation {
        journal?.snapshot() ?? .unavailable
    }

    private func parentPath(of path: String) -> String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        return String(path[..<slash])
    }

    private func record(
        _ kind: FakeOperation.Kind,
        path: String? = nil,
        depth: Int? = nil,
        requestBody: Data? = nil,
        ifMatch: String? = nil,
        resultStatus: Int?,
        responseBody: Data? = nil,
        responseETag: String? = nil,
        journal: JournalObservation
    ) {
        operations.append(
            FakeOperation(
                kind: kind,
                path: path,
                depth: depth,
                requestBody: requestBody,
                ifMatch: ifMatch,
                resultStatus: resultStatus,
                responseBody: responseBody,
                responseETag: responseETag,
                journal: journal
            )
        )
    }
}

private struct RecoveryScenario {
    struct File {
        let path: VerifierPath
        let body: Data
        let etag: StrongETag
    }

    let run: VerifierPath
    let files: [File]

    static func make() throws -> Self {
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-old-run")
        return Self(
            run: run,
            files: [
                File(
                    path: try VerifierPath(decodedRelativePath: run.description + "/root.txt"),
                    body: Data("root-body".utf8),
                    etag: try StrongETag(headerValue: "\"root-etag\"")
                ),
                File(
                    path: try VerifierPath(
                        decodedRelativePath: run.description + "/unicode-中文 space %.md"
                    ),
                    body: Data("special-body".utf8),
                    etag: try StrongETag(headerValue: "\"special-etag\"")
                ),
                File(
                    path: try VerifierPath(decodedRelativePath: run.description + "/final.txt"),
                    body: Data("deep-body".utf8),
                    etag: try StrongETag(headerValue: "\"deep-etag\"")
                ),
            ]
        )
    }

    var remoteResources: [RemoteResourceFixture] {
        files.map {
            .file($0.path, body: $0.body, etag: $0.etag.headerValue)
        }
    }

    var allowedDecodedPaths: [String] {
        files.map(\.path.description)
    }

    func seed(_ journal: RecoveryJournal) throws {
        try journal.start(
            runDirectory: run,
            scopeIdentifier: verifierTestScopeIdentifier
        )
        // Deliberately avoid deletion order: production must classify and sort.
        try journal.registerIntent(
            path: files[2].path,
            kind: .file,
            expectedBodies: [files[2].body],
            etag: files[2].etag
        )
        try journal.registerIntent(
            path: files[0].path,
            kind: .file,
            expectedBodies: [files[0].body],
            etag: files[0].etag
        )
        try journal.registerIntent(
            path: files[1].path,
            kind: .file,
            expectedBodies: [files[1].body],
            etag: files[1].etag
        )
        try journal.authorizeCleanup()
    }
}

private let verifierTestScopeIdentifier = "test-origin|test-root|test-account"

private func thrownError<T>(_ operation: () async throws -> T) async -> Error? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

private func decodedAllowlist(from record: RecoveryRecord) throws -> Set<String> {
    var paths = Set<String>()
    for resource in record.resources {
        paths.insert(try VerifierPath(percentEncodedRelativePath: resource.path).description)
    }
    return paths
}

private func mostFrequentlyWrittenPath(in operations: [FakeOperation]) -> String? {
    let paths = operations.compactMap { operation in
        operation.kind == .put ? operation.path : nil
    }
    return Dictionary(grouping: paths, by: { $0 })
        .max { $0.value.count < $1.value.count }?
        .key
}

private func indices(
    of kind: FakeOperation.Kind,
    path: String,
    in operations: [FakeOperation]
) -> [Int] {
    operations.indices.filter {
        operations[$0].kind == kind && operations[$0].path == path
    }
}

private func firstOperation(
    of kind: FakeOperation.Kind,
    path: String,
    after lowerBound: Int,
    before upperBound: Int? = nil,
    in operations: [FakeOperation]
) -> FakeOperation? {
    let end = upperBound ?? operations.endIndex
    guard lowerBound < end else { return nil }
    return operations[(lowerBound + 1)..<end].first {
        $0.kind == kind && $0.path == path
    }
}
