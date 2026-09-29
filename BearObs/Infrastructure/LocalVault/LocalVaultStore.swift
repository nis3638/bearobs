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
    case contentChanged
    case atomicWriteFailed(LocalVaultWriteCommitState)
}

public enum LocalVaultWriteCommitState: Equatable, Sendable {
    case notCommitted
    case committedButDurabilityUncertain
    case committedAndDurableButVerificationFailed
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

    public func coordinatedFileURL(for path: VaultPath) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(path.description, isDirectory: false)
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

    @discardableResult
    public func replace(
        _ path: VaultPath,
        with data: Data,
        expectedContentHash: ContentHash
    ) throws -> LocalVaultFileSnapshot {
        try validateRootIdentity()
        try withOpenParentDirectory(at: path) { directory, fileName in
            try replaceInParent(
                fileName,
                in: directory,
                with: data,
                expectedContentHash: expectedContentHash
            )
        }
        do {
            let snapshot = try read(path, maximumRetainedBytes: data.count)
            guard snapshot.data == data else {
                throw LocalVaultStoreError.atomicWriteFailed(
                    .committedAndDurableButVerificationFailed
                )
            }
            return snapshot
        } catch let error as LocalVaultStoreError {
            if case .atomicWriteFailed = error { throw error }
            throw LocalVaultStoreError.atomicWriteFailed(
                .committedAndDurableButVerificationFailed
            )
        } catch {
            throw LocalVaultStoreError.atomicWriteFailed(
                .committedAndDurableButVerificationFailed
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

    private func withOpenParentDirectory<T>(
        at path: VaultPath,
        operation: (Int32, String) throws -> T
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
        return try operation(directories.last!, components.last!)
    }

    private func replaceInParent(
        _ fileName: String,
        in directory: Int32,
        with data: Data,
        expectedContentHash: ContentHash
    ) throws {
        let existing = try openExistingFile(named: fileName, in: directory)
        defer { _ = Darwin.close(existing.descriptor) }
        guard try contentHash(of: existing.descriptor) == expectedContentHash else {
            throw LocalVaultStoreError.contentChanged
        }

        let stagingName = ".bearobs-staging-\(UUID().uuidString).tmp"
        let stagingDescriptor = openat(
            directory,
            stagingName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard stagingDescriptor >= 0 else {
            throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
        }
        let stagingIdentity: FileIdentity
        do {
            stagingIdentity = try identity(of: stagingDescriptor)
        } catch {
            _ = Darwin.close(stagingDescriptor)
            throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
        }
        var ownsStaging = true
        var stagingIsOpen = true
        defer {
            if stagingIsOpen { _ = Darwin.close(stagingDescriptor) }
            if ownsStaging {
                try? removeOwnedStaging(
                    named: stagingName,
                    identity: stagingIdentity,
                    in: directory
                )
            }
        }

        do {
            try writeAll(data, to: stagingDescriptor)
            guard
                fcopyfile(
                    existing.descriptor,
                    stagingDescriptor,
                    nil,
                    copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR)
                ) == 0
            else {
                throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
            }
            guard fchown(stagingDescriptor, existing.owner, existing.group) == 0 else {
                throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
            }
            guard fchmod(stagingDescriptor, existing.permissions) == 0 else {
                throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
            }
            guard fsync(stagingDescriptor) == 0 else {
                throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
            }
            stagingIsOpen = false
            guard Darwin.close(stagingDescriptor) == 0 else {
                throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
            }

            try requireIdentity(
                stagingIdentity,
                named: stagingName,
                in: directory
            )
            try requireCurrentDestination(
                named: fileName,
                identity: existing.identity,
                expectedContentHash: expectedContentHash,
                in: directory
            )
            try requireIdentity(
                stagingIdentity,
                named: stagingName,
                in: directory
            )
            guard renameat(directory, stagingName, directory, fileName) == 0 else {
                throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
            }
            ownsStaging = false
            guard fsync(directory) == 0 else {
                throw LocalVaultStoreError.atomicWriteFailed(
                    .committedButDurabilityUncertain
                )
            }
        } catch let error as LocalVaultStoreError {
            throw error
        } catch {
            throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
        }
    }

    private func openExistingFile(
        named name: String,
        in directory: Int32
    ) throws -> ExistingFile {
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw LocalVaultStoreError.unavailableFile }
        do {
            let information = try fileInformation(descriptor)
            return ExistingFile(
                descriptor: descriptor,
                identity: identity(of: information),
                permissions: information.st_mode & 0o7777,
                owner: information.st_uid,
                group: information.st_gid
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func requireCurrentDestination(
        named name: String,
        identity expectedIdentity: FileIdentity,
        expectedContentHash: ContentHash,
        in directory: Int32
    ) throws {
        let current = try openExistingFile(named: name, in: directory)
        defer { _ = Darwin.close(current.descriptor) }
        guard current.identity == expectedIdentity else {
            throw LocalVaultStoreError.contentChanged
        }
        guard try contentHash(of: current.descriptor) == expectedContentHash else {
            throw LocalVaultStoreError.contentChanged
        }
        var information = stat()
        guard fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw LocalVaultStoreError.contentChanged
        }
        guard identity(of: information) == current.identity else {
            throw LocalVaultStoreError.contentChanged
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    buffer.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
                }
                written += count
            }
        }
    }

    private func contentHash(of descriptor: Int32) throws -> ContentHash {
        let before = try fileInformation(descriptor)
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw LocalVaultStoreError.unavailableFile
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw LocalVaultStoreError.unavailableFile }
            if count == 0 { break }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        let after = try fileInformation(descriptor)
        guard isSameVersion(before, after) else {
            throw LocalVaultStoreError.contentChanged
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return try ContentHash(hex: hex)
    }

    private func requireIdentity(
        _ expected: FileIdentity,
        named name: String,
        in directory: Int32
    ) throws {
        var information = stat()
        guard fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
        }
        guard identity(of: information) == expected else {
            throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
        }
    }

    private func removeOwnedStaging(
        named name: String,
        identity expected: FileIdentity,
        in directory: Int32
    ) throws {
        var information = stat()
        guard fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw LocalVaultStoreError.unavailableFile
        }
        guard identity(of: information) == expected else { return }
        guard unlinkat(directory, name, 0) == 0 else {
            throw LocalVaultStoreError.unavailableFile
        }
    }

    private func identity(of descriptor: Int32) throws -> FileIdentity {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw LocalVaultStoreError.unavailableFile
        }
        return identity(of: information)
    }

    private func identity(of information: stat) -> FileIdentity {
        FileIdentity(device: information.st_dev, inode: information.st_ino)
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

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private struct ExistingFile {
    let descriptor: Int32
    let identity: FileIdentity
    let permissions: mode_t
    let owner: uid_t
    let group: gid_t
}
