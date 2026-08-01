import Darwin
import Foundation
import XCTest

@testable import AtomicWriteSpike

final class AtomicFileWriterTests: XCTestCase {
    func testSuccessfulWriteUsesSafeStageOrder() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            try Data("old".utf8).write(to: destination)
            var stages: [AtomicWriteStage] = []
            let writer = AtomicFileWriter(
                operations: POSIXAtomicFileOperations(),
                stagingName: { ".bearobs-staging-order.tmp" },
                checkpoint: { stages.append($0) }
            )

            _ = try writer.replaceExistingFile(
                at: destination,
                with: Data("new-complete".utf8)
            )

            XCTAssertEqual(stages, AtomicWriteStage.allCases)
        }
    }

    func testReplaceExistingFilePublishesExactBytesAndPreservesMode() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            try Data("old".utf8).write(to: destination)
            XCTAssertEqual(chmod(destination.path, 0o640), 0)

            let bytes =
                Data([0xEF, 0xBB, 0xBF])
                + Data("# New\r\n\r\nBody\r\n".utf8)
            let receipt = try AtomicFileWriter().replaceExistingFile(
                at: destination,
                with: bytes
            )

            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            XCTAssertEqual(receipt.byteCount, bytes.count)
            XCTAssertEqual(
                try AtomicWriteTestSupport.permissions(of: destination),
                0o640
            )
            XCTAssertEqual(
                try AtomicWriteTestSupport.stagingFiles(in: directory),
                []
            )
        }
    }

    func testWriterIsByteTransparent() throws {
        let samples = [
            Data(),
            Data("line one\nline two\n".utf8),
            Data("line one\r\nline two\r\n".utf8),
            Data("mixed\r\nline\n".utf8),
            Data([0xFF, 0x00, 0xFE, 0x0A]),
        ]

        for bytes in samples {
            try AtomicWriteTestSupport.withTemporaryDirectory { directory in
                let destination = directory.appendingPathComponent("note.md")
                try Data("old".utf8).write(to: destination)

                _ = try AtomicFileWriter().replaceExistingFile(
                    at: destination,
                    with: bytes
                )

                XCTAssertEqual(try Data(contentsOf: destination), bytes)
            }
        }
    }

    func testMissingDirectoryAndSymlinkDestinationsAreRejected() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let writer = AtomicFileWriter()
            let external = directory.appendingPathComponent("external.md")
            try Data("external".utf8).write(to: external)
            let symlink = directory.appendingPathComponent("link.md")
            try FileManager.default.createSymbolicLink(
                at: symlink,
                withDestinationURL: external
            )
            let subdirectory = directory.appendingPathComponent("folder")
            try FileManager.default.createDirectory(
                at: subdirectory,
                withIntermediateDirectories: false
            )

            for destination in [
                directory.appendingPathComponent("missing.md"),
                subdirectory,
                symlink,
            ] {
                XCTAssertThrowsError(
                    try writer.replaceExistingFile(
                        at: destination,
                        with: Data("new".utf8)
                    )
                ) { error in
                    XCTAssertEqual(
                        (error as? AtomicWriteFailure)?.commitState,
                        .notCommitted
                    )
                }
            }
            XCTAssertThrowsError(
                try writer.replaceExistingFile(
                    at: URL(string: "https://example.invalid/note.md")!,
                    with: Data("new".utf8)
                )
            )
            XCTAssertEqual(
                try Data(contentsOf: external),
                Data("external".utf8)
            )
        }
    }

    func testStagingCollisionDoesNotFollowOrDeleteSymlink() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("note.md")
            try Data("old".utf8).write(to: destination)
            let external = directory.appendingPathComponent("external")
            try Data("external".utf8).write(to: external)
            let staging = directory.appendingPathComponent(
                ".bearobs-staging-fixed.tmp"
            )
            try FileManager.default.createSymbolicLink(
                at: staging,
                withDestinationURL: external
            )
            let writer = AtomicFileWriter(
                operations: POSIXAtomicFileOperations(),
                stagingName: { ".bearobs-staging-fixed.tmp" }
            )

            XCTAssertThrowsError(
                try writer.replaceExistingFile(
                    at: destination,
                    with: Data("new".utf8)
                )
            )

            XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
            XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: staging.path)
            )
        }
    }
}
