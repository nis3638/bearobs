import Darwin
import Foundation
import XCTest

@testable import AtomicWriteSpike

final class AtomicWriteRaceTests: XCTestCase {
    func testConcurrentDestinationReplacementIsNotOverwritten() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            let externalUpdate = Data("external-update".utf8)
            try Data("old".utf8).write(to: destination)
            let writer = AtomicFileWriter(
                operations: POSIXAtomicFileOperations(),
                stagingName: { ".bearobs-staging-target-race.tmp" },
                checkpoint: { stage in
                    guard stage == .stagingClosed else { return }
                    try FileManager.default.removeItem(at: destination)
                    try externalUpdate.write(to: destination)
                }
            )

            XCTAssertThrowsError(
                try writer.replaceExistingFile(
                    at: destination,
                    with: Data("writer-update".utf8)
                )
            ) { error in
                XCTAssertEqual(
                    error as? AtomicWriteFailure,
                    .init(
                        operation: .replaceDestination,
                        code: ESTALE,
                        commitState: .notCommitted
                    )
                )
            }
            XCTAssertEqual(try Data(contentsOf: destination), externalUpdate)
            XCTAssertEqual(
                try AtomicWriteTestSupport.stagingFiles(in: directory),
                []
            )
        }
    }

    func testCleanupDoesNotDeleteAReplacementStagingEntry() throws {
        enum Cancellation: Error { case requested }

        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            let staging = directory.appendingPathComponent(
                ".bearobs-staging-cleanup-race.tmp"
            )
            let intruder = Data("not-owned-by-writer".utf8)
            try Data("old".utf8).write(to: destination)
            let writer = AtomicFileWriter(
                operations: POSIXAtomicFileOperations(),
                stagingName: { staging.lastPathComponent },
                checkpoint: { stage in
                    guard stage == .partialDataWritten else { return }
                    try FileManager.default.removeItem(at: staging)
                    try intruder.write(to: staging)
                    throw Cancellation.requested
                }
            )

            XCTAssertThrowsError(
                try writer.replaceExistingFile(
                    at: destination,
                    with: Data(repeating: 0x4E, count: 64)
                )
            ) { error in
                XCTAssertEqual((error as? AtomicWriteFailure)?.code, ECANCELED)
            }
            XCTAssertEqual(try Data(contentsOf: staging), intruder)
            XCTAssertEqual(
                try Data(contentsOf: destination),
                Data("old".utf8)
            )
        }
    }

    func testParentPathReplacementDoesNotRedirectOpenTransaction() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { root in
            let vault = root.appendingPathComponent("vault")
            let movedVault = root.appendingPathComponent("moved-vault")
            try FileManager.default.createDirectory(
                at: vault,
                withIntermediateDirectories: false
            )
            let destination = vault.appendingPathComponent("note.md")
            let new = Data("new-in-original-directory".utf8)
            let decoy = Data("decoy-at-reused-path".utf8)
            try Data("old".utf8).write(to: destination)
            let writer = AtomicFileWriter(
                operations: POSIXAtomicFileOperations(),
                stagingName: { ".bearobs-staging-parent-race.tmp" },
                checkpoint: { stage in
                    guard stage == .stagingCreated else { return }
                    try FileManager.default.moveItem(at: vault, to: movedVault)
                    try FileManager.default.createDirectory(
                        at: vault,
                        withIntermediateDirectories: false
                    )
                    try decoy.write(
                        to: vault.appendingPathComponent("note.md")
                    )
                }
            )

            _ = try writer.replaceExistingFile(at: destination, with: new)

            XCTAssertEqual(
                try Data(contentsOf: movedVault.appendingPathComponent("note.md")),
                new
            )
            XCTAssertEqual(try Data(contentsOf: destination), decoy)
        }
    }

    func testVerificationRejectsPostPublishFIFOReplacementWithoutBlocking()
        throws
    {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            try Data("old".utf8).write(to: destination)
            let writer = AtomicFileWriter(
                operations: POSIXAtomicFileOperations(),
                stagingName: { ".bearobs-staging-verify-race.tmp" },
                checkpoint: { stage in
                    guard stage == .destinationReplaced else { return }
                    try FileManager.default.removeItem(at: destination)
                    guard mkfifo(destination.path, 0o600) == 0 else {
                        throw POSIXError(
                            POSIXErrorCode(rawValue: errno) ?? .EIO
                        )
                    }
                }
            )

            XCTAssertThrowsError(
                try writer.replaceExistingFile(
                    at: destination,
                    with: Data("new".utf8)
                )
            ) { error in
                XCTAssertEqual(
                    (error as? AtomicWriteFailure)?.operation,
                    .verifyDestination
                )
                XCTAssertEqual(
                    (error as? AtomicWriteFailure)?.commitState,
                    .committedAndDurableButVerificationFailed
                )
            }
        }
    }
}
