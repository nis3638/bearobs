import Darwin
import Foundation
import XCTest

@testable import AtomicWriteSpike

final class AtomicWriteFailureTests: XCTestCase {
    func testFailuresBeforePublishKeepOldFileAndCleanOwnedStaging() throws {
        let cases: [(FaultingOperations.Fault, AtomicWriteOperation, Int32)] = [
            (.partialWrite, .writeStaging, ENOSPC),
            (.setPermissions, .setPermissions, EPERM),
            (.synchronizeFile, .synchronizeStaging, EIO),
            (.closeFile, .closeStaging, EIO),
            (.publish, .replaceDestination, EIO),
        ]

        for (fault, operation, code) in cases {
            try AtomicWriteTestSupport.withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("note.md")
                let old = Data("old-complete".utf8)
                let new = Data(repeating: 0x4E, count: 16_384)
                try old.write(to: destination)
                let writer = AtomicFileWriter(
                    operations: FaultingOperations(fault: fault),
                    stagingName: {
                        ".bearobs-staging-\(fault).tmp"
                    }
                )

                XCTAssertThrowsError(
                    try writer.replaceExistingFile(at: destination, with: new)
                ) { error in
                    XCTAssertEqual(
                        error as? AtomicWriteFailure,
                        .init(
                            operation: operation,
                            code: code,
                            commitState: .notCommitted
                        ),
                        "\(fault)"
                    )
                }
                XCTAssertEqual(try Data(contentsOf: destination), old, "\(fault)")
                XCTAssertEqual(
                    try AtomicWriteTestSupport.stagingFiles(in: directory),
                    [],
                    "\(fault)"
                )
            }
        }
    }

    func testFailuresAfterPublishReportAccurateCommitState() throws {
        let cases: [(FaultingOperations.Fault, AtomicWriteCommitState)] = [
            (.synchronizeDirectory, .committedButDurabilityUncertain),
            (.verifyDestination, .committedAndDurableButVerificationFailed),
            (.verifyMismatch, .committedAndDurableButVerificationFailed),
        ]
        for (fault, expectedState) in cases {
            try AtomicWriteTestSupport.withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("note.md")
                let new = Data(repeating: 0x4E, count: 16_384)
                try Data("old-complete".utf8).write(to: destination)
                let writer = AtomicFileWriter(
                    operations: FaultingOperations(fault: fault),
                    stagingName: { ".bearobs-staging-post-publish.tmp" }
                )

                XCTAssertThrowsError(
                    try writer.replaceExistingFile(at: destination, with: new)
                ) { error in
                    XCTAssertEqual(
                        (error as? AtomicWriteFailure)?.commitState,
                        expectedState,
                        "\(fault)"
                    )
                }
                XCTAssertEqual(try Data(contentsOf: destination), new, "\(fault)")
                XCTAssertEqual(
                    try AtomicWriteTestSupport.stagingFiles(in: directory),
                    [],
                    "\(fault)"
                )
            }
        }
    }

    func testCheckpointCancellationIsNotCommittedAndCleansStaging() throws {
        enum Cancellation: Error { case requested }

        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            let old = Data("old-complete".utf8)
            try old.write(to: destination)
            let writer = AtomicFileWriter { stage in
                if stage == .dataWritten {
                    throw Cancellation.requested
                }
            }

            XCTAssertThrowsError(
                try writer.replaceExistingFile(
                    at: destination,
                    with: Data("new-complete".utf8)
                )
            ) { error in
                XCTAssertEqual((error as? AtomicWriteFailure)?.code, ECANCELED)
                XCTAssertEqual(
                    (error as? AtomicWriteFailure)?.commitState,
                    .notCommitted
                )
            }
            XCTAssertEqual(try Data(contentsOf: destination), old)
            XCTAssertEqual(
                try AtomicWriteTestSupport.stagingFiles(in: directory),
                []
            )
        }
    }

    func testCleanupFailureDoesNotHideOriginalWriteFailure() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            let old = Data("old-complete".utf8)
            try old.write(to: destination)
            let operations = FaultingOperations(
                fault: .partialWrite,
                cleanupAlsoFails: true
            )
            let writer = AtomicFileWriter(
                operations: operations,
                stagingName: { ".bearobs-staging-cleanup-failure.tmp" }
            )

            XCTAssertThrowsError(
                try writer.replaceExistingFile(
                    at: destination,
                    with: Data(repeating: 0x4E, count: 8_192)
                )
            ) { error in
                XCTAssertEqual(
                    (error as? AtomicWriteFailure)?.operation,
                    .writeStaging
                )
            }
            XCTAssertEqual(try Data(contentsOf: destination), old)
            XCTAssertEqual(
                try AtomicWriteTestSupport.stagingFiles(in: directory).count,
                1
            )
        }
    }
}

private final class FaultingOperations: AtomicFileOperations {
    enum Fault: Equatable {
        case partialWrite
        case setPermissions
        case synchronizeFile
        case closeFile
        case publish
        case synchronizeDirectory
        case verifyDestination
        case verifyMismatch

    }

    private let base = POSIXAtomicFileOperations()
    private let fault: Fault
    private let cleanupAlsoFails: Bool
    private var fired = false

    init(fault: Fault, cleanupAlsoFails: Bool = false) {
        self.fault = fault
        self.cleanupAlsoFails = cleanupAlsoFails
    }

    func openDirectory(at path: String) throws -> Int32 {
        try base.openDirectory(at: path)
    }

    func existingRegularFile(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> AtomicExistingFile {
        try base.existingRegularFile(named: name, in: directoryDescriptor)
    }

    func openExclusiveStaging(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> AtomicStagingFile {
        try base.openExclusiveStaging(named: name, in: directoryDescriptor)
    }

    func writeAll(_ data: Data, to descriptor: Int32) throws {
        if fault == .partialWrite, !fired {
            fired = true
            try base.writeAll(Data(data.prefix(32)), to: descriptor)
            throw AtomicPOSIXError(code: ENOSPC)
        }
        try base.writeAll(data, to: descriptor)
    }

    func setPermissions(_ permissions: UInt16, of descriptor: Int32) throws {
        try failOnce(.setPermissions, code: EPERM)
        try base.setPermissions(permissions, of: descriptor)
    }

    func synchronizeFile(_ descriptor: Int32) throws {
        try failOnce(.synchronizeFile, code: EIO)
        try base.synchronizeFile(descriptor)
    }

    func closeFile(_ descriptor: Int32) throws {
        if fault == .closeFile, !fired {
            fired = true
            try base.closeFile(descriptor)
            throw AtomicPOSIXError(code: EIO)
        }
        try base.closeFile(descriptor)
    }

    func publish(
        stagingName: String,
        stagingIdentity: AtomicFileIdentity,
        destinationName: String,
        destinationIdentity: AtomicFileIdentity,
        in directoryDescriptor: Int32
    ) throws {
        try failOnce(.publish, code: EIO)
        try base.publish(
            stagingName: stagingName,
            stagingIdentity: stagingIdentity,
            destinationName: destinationName,
            destinationIdentity: destinationIdentity,
            in: directoryDescriptor
        )
    }

    func synchronizeDirectory(_ descriptor: Int32) throws {
        try failOnce(.synchronizeDirectory, code: EIO)
        try base.synchronizeDirectory(descriptor)
    }

    func readFile(
        named name: String,
        expectedIdentity: AtomicFileIdentity,
        expectedByteCount: Int,
        in directoryDescriptor: Int32
    ) throws -> Data {
        if fault == .verifyMismatch, !fired {
            fired = true
            return Data("mismatch".utf8)
        }
        try failOnce(.verifyDestination, code: EIO)
        return try base.readFile(
            named: name,
            expectedIdentity: expectedIdentity,
            expectedByteCount: expectedByteCount,
            in: directoryDescriptor
        )
    }

    func removeOwnedStaging(
        named name: String,
        identity: AtomicFileIdentity,
        in directoryDescriptor: Int32
    ) throws {
        if cleanupAlsoFails {
            throw AtomicPOSIXError(code: EACCES)
        }
        try base.removeOwnedStaging(
            named: name,
            identity: identity,
            in: directoryDescriptor
        )
    }

    private func failOnce(_ expected: Fault, code: Int32) throws {
        if fault == expected, !fired {
            fired = true
            throw AtomicPOSIXError(code: code)
        }
    }
}
