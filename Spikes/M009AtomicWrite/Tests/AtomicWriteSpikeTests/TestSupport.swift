import Darwin
import Foundation

@testable import AtomicWriteSpike

enum AtomicWriteTestSupport {
    static func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearobs-m009-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    static func permissions(of url: URL) throws -> UInt16 {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return UInt16(information.st_mode & 0o7777)
    }

    static func stagingFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".bearobs-staging-")
        }
    }
}
