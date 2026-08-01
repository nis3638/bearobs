import Darwin
import Foundation
import XCTest

@testable import AtomicWriteSpike

final class POSIXAtomicFileOperationsTests: XCTestCase {
    func testWriteAllRetriesEINTRAndCompletesShortWrites() throws {
        try AtomicWriteTestSupport.withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("output")
            let descriptor = open(
                destination.path,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                0o600
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { _ = Darwin.close(descriptor) }
            var callCount = 0
            let operations = POSIXAtomicFileOperations {
                descriptor, buffer, count in
                callCount += 1
                if callCount == 1 {
                    errno = EINTR
                    return -1
                }
                return Darwin.write(descriptor, buffer, min(count, 3))
            }
            let expected = Data("short-write-retry".utf8)

            try operations.writeAll(expected, to: descriptor)

            XCTAssertGreaterThan(callCount, 2)
            XCTAssertEqual(try Data(contentsOf: destination), expected)
        }
    }

    func testWriteAllRejectsZeroLengthProgress() throws {
        let operations = POSIXAtomicFileOperations { _, _, _ in 0 }

        XCTAssertThrowsError(
            try operations.writeAll(Data("nonempty".utf8), to: -1)
        ) { error in
            XCTAssertEqual((error as? AtomicPOSIXError)?.code, EIO)
        }
    }
}
