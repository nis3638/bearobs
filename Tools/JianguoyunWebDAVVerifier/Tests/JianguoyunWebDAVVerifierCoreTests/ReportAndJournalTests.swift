import Foundation
import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class ReportAndJournalTests: XCTestCase {
    func testReportRendererHasClosedSchemaAndCannotRenderSensitiveValues() {
        let report = VerificationReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            toolVersion: .v1,
            results: [
                CapabilityResult(
                    capability: .staleETagPrecondition,
                    status: .pass,
                    httpStatus: 412,
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

        let rendered = SanitizedReportRenderer().render(report)

        XCTAssertTrue(rendered.contains("stale-etag-precondition PASS http=412 body-unchanged"))
        XCTAssertTrue(
            rendered.contains(
                "pagination-beyond-750 BLOCKED vendor-pagination-protocol-undocumented"
            )
        )
        for forbidden in [
            "https://", "dav/", "Authorization", "username", "password", "private-root",
            "\"etag-value\"",
        ] {
            XCTAssertFalse(rendered.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
    }

    func testJournalPersistsCleanupIntentWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("recovery.json")
        let journal = RecoveryJournal(fileURL: file)
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-test")
        let resource = try VerifierPath(decodedRelativePath: "bearobs-m0-11-test/note.md")
        defer { try? FileManager.default.removeItem(at: directory) }

        try journal.start(runDirectory: run, scopeIdentifier: journalTestScopeIdentifier)
        try journal.registerIntent(
            path: resource,
            kind: .file,
            expectedBodies: [Data("one".utf8), Data("two".utf8)],
            etag: try StrongETag(headerValue: "\"opaque\"")
        )

        let record = try XCTUnwrap(journal.load())
        XCTAssertEqual(record.state, .cleanupPending)
        XCTAssertEqual(record.runDirectory, run.percentEncodedRelativePath)
        XCTAssertEqual(record.resources.count, 1)
        XCTAssertEqual(record.resources[0].path, resource.percentEncodedRelativePath)
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("one"))
        XCTAssertEqual(try permissions(of: directory), 0o700)
        XCTAssertEqual(try permissions(of: file), 0o600)

        try journal.markManualReview()
        XCTAssertEqual(try journal.load()?.state, .manualReview)
        try journal.clear()
        XCTAssertNil(try journal.load())
    }

    func testMissingETagCannotProveOwnership() throws {
        let record = try ResourceRecord(
            path: "run/file",
            kind: .file,
            expectedBodyHashes: [String(repeating: "0", count: 64)],
            etagHash: nil
        )

        XCTAssertFalse(record.matchesETag(nil))
    }

    func testIndependentJournalInstancesSerializeConcurrentUpdates() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("recovery.json")
        let journals = [RecoveryJournal(fileURL: file), RecoveryJournal(fileURL: file)]
        let run = try VerifierPath(decodedRelativePath: "bearobs-m0-11-concurrent")
        let resourceCount = 64
        defer { try? FileManager.default.removeItem(at: directory) }

        try journals[0].start(
            runDirectory: run,
            scopeIdentifier: journalTestScopeIdentifier
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<resourceCount {
                group.addTask {
                    let path = try VerifierPath(
                        decodedRelativePath: run.description + "/file-\(index).md"
                    )
                    try journals[index % journals.count].registerIntent(
                        path: path,
                        kind: .file,
                        expectedBodies: [Data("body-\(index)".utf8)],
                        etag: nil
                    )
                }
            }
            try await group.waitForAll()
        }

        let record = try XCTUnwrap(journals[1].load())
        XCTAssertEqual(record.resources.count, resourceCount)
        XCTAssertEqual(Set(record.resources.map(\.path)).count, resourceCount)
    }

    func testRunLeaseRejectsASecondVerifierLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("recovery.json")
        let first = RecoveryJournal(fileURL: file)
        let second = RecoveryJournal(fileURL: file)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lease = try first.acquireRunLease()
        try withExtendedLifetime(lease) {
            XCTAssertThrowsError(try second.acquireRunLease()) { error in
                XCTAssertEqual(error as? RecoveryJournalError, .runInProgress)
            }
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}

private let journalTestScopeIdentifier = "test-origin|test-root|test-account"
