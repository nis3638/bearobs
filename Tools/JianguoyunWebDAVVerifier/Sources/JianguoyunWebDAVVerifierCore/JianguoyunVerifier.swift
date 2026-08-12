import Foundation

/// Orchestrates one isolated, synthetic WebDAV capability verification run.
public struct JianguoyunVerifier: Sendable {
    private let remote: any VerifierRemote
    private let journal: RecoveryJournal
    private let runComponent: String
    private let scopeIdentifier: String

    public init(
        remote: any VerifierRemote,
        journal: RecoveryJournal,
        runComponent: String,
        scopeIdentifier: String
    ) {
        self.remote = remote
        self.journal = journal
        self.runComponent = runComponent
        self.scopeIdentifier = scopeIdentifier
    }

    public func verify() async throws -> VerificationReport {
        let lease: RecoveryJournalLease
        do {
            lease = try journal.acquireRunLease()
        } catch RecoveryJournalError.runInProgress {
            throw VerifierFailure.runAlreadyInProgress
        } catch is RecoveryJournalError {
            throw VerifierFailure.manualReviewRequired
        } catch {
            throw VerifierFailure.remoteOperationFailed
        }
        defer { withExtendedLifetime(lease) {} }

        do {
            try await recoverPendingRun()
        } catch {
            throw mapRecoveryError(error)
        }

        do {
            let report = try await performFreshRun()
            try await cleanupPendingRun()
            return report
        } catch {
            let verificationError = mapRemoteError(error)
            do {
                try await cleanupPendingRun()
            } catch {
                throw mapCleanupError(error)
            }
            throw verificationError
        }
    }

    private func recoverPendingRun() async throws {
        guard let record = try journal.load() else { return }
        guard record.matchesScopeIdentifier(scopeIdentifier) else {
            try journal.markManualReview()
            throw VerifierFailure.manualReviewRequired
        }
        try await finishCleanup(record)
    }

    private func performFreshRun() async throws -> VerificationReport {
        guard try await remote.unauthenticatedDepthZeroStatus() == 401 else {
            throw VerifierFailure.authenticationProbeFailed
        }
        try await proveDedicatedRootIsEmpty()

        let exchange = try VerifierPath(
            decodedRelativePath: runComponent + "-unicode-中文 space %.md"
        )
        let baseline = Data("# BearObs WebDAV verification\n\nbaseline\n".utf8)
        let updated = Data("# BearObs WebDAV verification\n\nupdated\n".utf8)
        let stale = Data("# BearObs WebDAV verification\n\nstale-write-must-fail\n".utf8)

        try journal.start(runDirectory: exchange, scopeIdentifier: scopeIdentifier)
        try journal.registerIntent(
            path: exchange,
            kind: .file,
            expectedBodies: [baseline, updated, stale],
            etag: nil
        )
        guard try await remote.put(path: exchange, body: baseline, ifMatch: nil) == 201 else {
            try journal.markManualReview()
            throw VerifierFailure.manualReviewRequired
        }

        let firstRead = try await readExpectedBody(baseline, at: exchange)
        let firstETag = try strongETag(from: firstRead.etagHeader)

        guard try await remote.put(path: exchange, body: updated, ifMatch: firstETag) == 204 else {
            throw VerifierFailure.invalidHTTPStatus
        }

        let secondRead = try await readExpectedBody(updated, at: exchange)
        let secondETag = try strongETag(from: secondRead.etagHeader)
        guard secondETag != firstETag else {
            throw VerifierFailure.missingStrongETag
        }

        let staleDeleteStatus = try await remote.delete(path: exchange, ifMatch: firstETag)
        guard staleDeleteStatus == 412 else {
            throw VerifierFailure.staleDeleteWasAccepted
        }
        let readAfterStaleDelete = try await readExpectedBody(updated, at: exchange)
        guard let deleteProbeHeader = readAfterStaleDelete.etagHeader,
            let deleteProbeETag = try? StrongETag(headerValue: deleteProbeHeader),
            deleteProbeETag == secondETag
        else {
            throw VerifierFailure.staleDeleteChangedResource
        }
        try journal.authorizeCleanup()

        let staleStatus = try await remote.put(path: exchange, body: stale, ifMatch: firstETag)
        guard staleStatus == 412 else {
            throw VerifierFailure.staleWriteWasAccepted
        }

        let finalRead = try await remote.get(path: exchange)
        guard finalRead.statusCode == 200 else {
            throw VerifierFailure.invalidHTTPStatus
        }
        guard finalRead.body == updated else {
            throw VerifierFailure.staleWriteChangedBody
        }
        guard let finalHeader = finalRead.etagHeader,
            let finalETag = try? StrongETag(headerValue: finalHeader),
            finalETag == secondETag
        else {
            throw VerifierFailure.staleWriteChangedBody
        }

        return VerificationReport(
            generatedAt: Date(),
            toolVersion: .v1,
            results: [
                CapabilityResult(
                    capability: .staleETagPrecondition,
                    status: .pass,
                    httpStatus: staleStatus,
                    reason: nil,
                    evidence: []
                ),
                CapabilityResult(
                    capability: .staleWritePreservesBody,
                    status: .pass,
                    httpStatus: nil,
                    reason: nil,
                    evidence: [.bodyUnchanged]
                ),
                CapabilityResult(
                    capability: .staleDeletePrecondition,
                    status: .pass,
                    httpStatus: staleDeleteStatus,
                    reason: nil,
                    evidence: [.bodyUnchanged]
                ),
                CapabilityResult(
                    capability: .paginationBeyond750,
                    status: .blocked,
                    httpStatus: nil,
                    reason: .vendorPaginationProtocolUndocumented,
                    evidence: []
                ),
            ]
        )
    }

    private func proveDedicatedRootIsEmpty() async throws {
        let depthZero = try await remote.list(path: nil, depth: 0)
        guard depthZero.statusCode == 207 else {
            throw VerifierFailure.dedicatedDirectoryHTTPStatus(
                depth: 0,
                status: depthZero.statusCode
            )
        }
        guard depthZero.entries.count == 1,
            depthZero.entries[0].path == nil,
            depthZero.entries[0].isCollection
        else {
            throw VerifierFailure.dedicatedDirectoryUnavailable
        }

        let depthOne = try await remote.list(path: nil, depth: 1)
        guard depthOne.statusCode == 207 else {
            throw VerifierFailure.dedicatedDirectoryHTTPStatus(
                depth: 1,
                status: depthOne.statusCode
            )
        }
        guard depthOne.entries.count == 1,
            depthOne.entries[0].path == nil,
            depthOne.entries[0].isCollection
        else {
            throw VerifierFailure.dedicatedDirectoryNotEmpty
        }
    }

    private func readExpectedBody(_ expected: Data, at path: VerifierPath) async throws
        -> RemoteRead
    {
        let read = try await remote.get(path: path)
        guard read.statusCode == 200 else {
            throw VerifierFailure.invalidHTTPStatus
        }
        guard read.body == expected else {
            throw VerifierFailure.responseBodyMismatch
        }
        return read
    }

    private func strongETag(from header: String?) throws -> StrongETag {
        guard let header, let etag = try? StrongETag(headerValue: header) else {
            throw VerifierFailure.missingStrongETag
        }
        return etag
    }

    private func cleanupPendingRun() async throws {
        guard let record = try journal.load() else { return }
        try await finishCleanup(record)
    }

    private func finishCleanup(_ record: RecoveryRecord) async throws {
        switch record.state {
        case .cleanupAuthorized:
            try await cleanup(record)
        case .cleanupPending:
            try await finishUnprovenCleanup(record)
        case .manualReview:
            throw VerifierFailure.manualReviewRequired
        }
    }

    /// A crash before the stale DELETE probe leaves deletion semantics unknown.
    /// Reads may prove that no resource exists, but automatic DELETE is forbidden.
    private func finishUnprovenCleanup(_ record: RecoveryRecord) async throws {
        let plan = try await makeCleanupPlan(record)
        guard plan.files.isEmpty else {
            try journal.markManualReview()
            throw VerifierFailure.manualReviewRequired
        }
        try journal.clear()
    }

    private func cleanup(_ record: RecoveryRecord) async throws {
        let plan = try await makeCleanupPlan(record)

        for resource in plan.files {
            let status = try await remote.delete(
                path: resource.path,
                ifMatch: resource.deleteETag
            )
            guard status == 404 || (200...299).contains(status) else {
                throw VerifierFailure.cleanupFailed
            }
            guard try await confirmsMissing(resource) else {
                throw VerifierFailure.cleanupFailed
            }
        }
        try journal.clear()
    }

    private func makeCleanupPlan(_ record: RecoveryRecord) async throws -> CleanupPlan {
        do {
            return try await proveCleanupOwnership(record)
        } catch let failure as OwnershipFailure {
            switch failure {
            case .mismatch:
                try journal.markManualReview()
                throw VerifierFailure.manualReviewRequired
            case .remoteStatus:
                throw VerifierFailure.cleanupFailed
            }
        }
    }

    /// This phase is deliberately mutation-free. The complete allowlist must be
    /// proven before the first DELETE can be issued.
    private func proveCleanupOwnership(_ record: RecoveryRecord) async throws -> CleanupPlan {
        let resources = try record.resources.map { item in
            CleanupResource(
                path: try VerifierPath(percentEncodedRelativePath: item.path),
                kind: item.kind,
                record: item,
                deleteETag: nil
            )
        }
        var existing: [CleanupResource] = []
        for resource in resources {
            switch resource.kind {
            case .file:
                if let proven = try await proveFile(resource) {
                    existing.append(proven)
                }
            case .collection:
                throw OwnershipFailure.mismatch
            }
        }

        let files =
            existing
            .filter { $0.kind == .file }
            .sorted { $0.path.description < $1.path.description }
        return CleanupPlan(files: files)
    }

    private func proveFile(_ resource: CleanupResource) async throws -> CleanupResource? {
        let read = try await remote.get(path: resource.path)
        if read.statusCode == 404 { return nil }
        guard read.statusCode == 200 else { throw OwnershipFailure.remoteStatus }
        guard let record = resource.record, record.matchesExpectedBody(read.body) else {
            throw OwnershipFailure.mismatch
        }
        guard let header = read.etagHeader,
            let etag = try? StrongETag(headerValue: header)
        else {
            throw OwnershipFailure.mismatch
        }
        if record.etagHash != nil {
            guard record.matchesETag(etag) else { throw OwnershipFailure.mismatch }
        }
        return CleanupResource(
            path: resource.path,
            kind: resource.kind,
            record: resource.record,
            deleteETag: etag
        )
    }

    private func confirmsMissing(_ resource: CleanupResource) async throws -> Bool {
        switch resource.kind {
        case .file:
            return try await remote.get(path: resource.path).statusCode == 404
        case .collection:
            return try await remote.list(path: resource.path, depth: 1).statusCode == 404
        }
    }

    private func mapRemoteError(_ error: Error) -> VerifierFailure {
        error as? VerifierFailure ?? .remoteOperationFailed
    }

    private func mapRecoveryError(_ error: Error) -> VerifierFailure {
        if let failure = error as? VerifierFailure { return failure }
        if error is RecoveryJournalError { return .manualReviewRequired }
        return .cleanupFailed
    }

    private func mapCleanupError(_ error: Error) -> VerifierFailure {
        guard let failure = error as? VerifierFailure else { return .cleanupFailed }
        switch failure {
        case .manualReviewRequired:
            return .manualReviewRequired
        default:
            return .cleanupFailed
        }
    }

}

private enum OwnershipFailure: Error, Equatable {
    case mismatch
    case remoteStatus
}

private struct CleanupResource {
    let path: VerifierPath
    let kind: RecoveryResourceKind
    let record: ResourceRecord?
    let deleteETag: StrongETag?
}

private struct CleanupPlan {
    let files: [CleanupResource]
}
