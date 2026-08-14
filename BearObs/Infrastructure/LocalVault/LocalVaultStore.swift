import CryptoKit
import Darwin
import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public enum LocalVaultStoreError: Error, Equatable, Sendable {
    case invalidRoot
    case unavailableRoot
    case rootIsSymbolicLink
    case rootIsNotDirectory
    case rootChanged
    case unavailableFile
    case fileIsNotRegular
    case fileChangedDuringRead
    case invalidReadLimit
}

public struct LocalVaultFileMetadata: Equatable, Sendable {
    public let path: VaultPath
    public let modifiedAt: Date
    public let byteSize: Int64

    init(path: VaultPath, information: stat) {
        self.path = path
        modifiedAt = Date(
            timeIntervalSince1970: Double(information.st_mtimespec.tv_sec)
                + Double(information.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        byteSize = information.st_size
    }
}

public struct LocalVaultFileSnapshot: Sendable {
    public let metadata: LocalVaultFileMetadata
    public let contentHash: ContentHash
    public let data: Data?
}

public struct LocalVaultStore: Sendable {
    private let rootPath: String
    private let rootDevice: dev_t
    private let rootInode: ino_t

    public init(root: URL) throws {
        guard root.isFileURL else { throw LocalVaultStoreError.invalidRoot }
        var information = stat()
        guard lstat(root.path, &information) == 0 else {
            throw LocalVaultStoreError.unavailableRoot
        }
        switch information.st_mode & S_IFMT {
        case S_IFLNK:
            throw LocalVaultStoreError.rootIsSymbolicLink
        case S_IFDIR:
            rootPath = root.path
            rootDevice = information.st_dev
            rootInode = information.st_ino
        default:
            throw LocalVaultStoreError.rootIsNotDirectory
        }
    }

    public func markdownFiles() throws -> [LocalVaultFileMetadata] {
        try validateRootIdentity()
        var result: [LocalVaultFileMetadata] = []
        try LocalVaultEnumerator().enumerateMarkdown(
            at: URL(fileURLWithPath: rootPath, isDirectory: true)
        ) { path in
            result.append(try metadata(for: path))
        }
        try validateRootIdentity()
        return result
    }

    public func read(
        _ path: VaultPath,
        maximumRetainedBytes: Int
    ) throws -> LocalVaultFileSnapshot {
        guard maximumRetainedBytes >= 0 else {
            throw LocalVaultStoreError.invalidReadLimit
        }
        return try withOpenFile(at: path) { descriptor in
            let before = try fileInformation(descriptor)
            var hasher = SHA256()
            var retained = before.st_size <= maximumRetainedBytes ? Data() : nil
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)

            while true {
                try Task.checkCancellation()
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw LocalVaultStoreError.unavailableFile }
                if count == 0 { break }
                let chunk = Data(buffer.prefix(count))
                hasher.update(data: chunk)
                retained = retained.flatMap { accumulated in
                    guard accumulated.count + chunk.count <= maximumRetainedBytes else {
                        return nil
                    }
                    var copy = accumulated
                    copy.append(chunk)
                    return copy
                }
            }

            let after = try fileInformation(descriptor)
            guard isSameVersion(before, after) else {
                throw LocalVaultStoreError.fileChangedDuringRead
            }
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return LocalVaultFileSnapshot(
                metadata: LocalVaultFileMetadata(path: path, information: after),
                contentHash: try ContentHash(hex: hex),
                data: retained
            )
        }
    }
}

extension LocalVaultStore {
    private func metadata(for path: VaultPath) throws -> LocalVaultFileMetadata {
        try withOpenFile(at: path) {
            LocalVaultFileMetadata(path: path, information: try fileInformation($0))
        }
    }

    private func withOpenFile<T>(
        at path: VaultPath,
        operation: (Int32) throws -> T
    ) throws -> T {
        let root = try openRoot()
        var directories = [root]
        defer {
            for descriptor in directories.reversed() {
                _ = Darwin.close(descriptor)
            }
        }

        let components = path.description.split(separator: "/").map(String.init)
        for component in components.dropLast() {
            let child = openat(
                directories.last!,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard child >= 0 else { throw LocalVaultStoreError.unavailableFile }
            directories.append(child)
        }

        let file = openat(
            directories.last!,
            components.last!,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard file >= 0 else { throw LocalVaultStoreError.unavailableFile }
        defer { _ = Darwin.close(file) }
        return try operation(file)
    }

    private func fileInformation(_ descriptor: Int32) throws -> stat {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw LocalVaultStoreError.unavailableFile
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw LocalVaultStoreError.fileIsNotRegular
        }
        return information
    }

    private func validateRootIdentity() throws {
        let descriptor = try openRoot()
        _ = Darwin.close(descriptor)
    }

    private func openRoot() throws -> Int32 {
        let descriptor = open(
            rootPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw LocalVaultStoreError.unavailableRoot }
        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw LocalVaultStoreError.unavailableRoot
            }
            guard information.st_dev == rootDevice, information.st_ino == rootInode else {
                throw LocalVaultStoreError.rootChanged
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func isSameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}
