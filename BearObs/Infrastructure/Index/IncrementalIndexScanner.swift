import CryptoKit
import Darwin
import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsLocalVault
    import BearObsMarkdown
#endif

public struct IncrementalIndexReport: Equatable, Sendable {
    public let metadataSkipped: Int
    public let hashSkipped: Int
    public let indexed: Int
    public let failed: Int
    public let removed: Int

    public init(
        metadataSkipped: Int = 0,
        hashSkipped: Int = 0,
        indexed: Int = 0,
        failed: Int = 0,
        removed: Int = 0
    ) {
        self.metadataSkipped = metadataSkipped
        self.hashSkipped = hashSkipped
        self.indexed = indexed
        self.failed = failed
        self.removed = removed
    }
}

public struct FullIndexRebuildReport: Equatable, Sendable {
    public let indexed: Int
    public let failed: Int

    public init(indexed: Int = 0, failed: Int = 0) {
        self.indexed = indexed
        self.failed = failed
    }
}

public enum IndexedSourceSnapshotStoreError: Error, Equatable, Sendable {
    case invalidDirectory
    case unavailableDirectory
    case directoryIsSymbolicLink
    case directoryIsNotDirectory
    case directoryChanged
    case snapshotIsSymbolicLink
    case snapshotIsNotRegular
    case snapshotTooLarge
    case contentHashMismatch
    case readFailed
    case writeFailed
}

private final class IndexedSourceSnapshotStoreLock: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

/// Content-addressed, app-sandbox-only source snapshots used by the read-only
/// client when a previously indexed File Provider item is temporarily offline.
/// The full bytes are retained so BOM, frontmatter, line endings and absolute
/// source ranges stay identical to the successfully indexed file.
public struct IndexedSourceSnapshotStore: Sendable {
    private let directoryPath: String
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let accessLock: IndexedSourceSnapshotStoreLock

    public init(directory: URL) throws {
        guard directory.isFileURL else {
            throw IndexedSourceSnapshotStoreError.invalidDirectory
        }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        } catch {
            throw IndexedSourceSnapshotStoreError.unavailableDirectory
        }
        var information = stat()
        guard lstat(directory.path, &information) == 0 else {
            throw IndexedSourceSnapshotStoreError.unavailableDirectory
        }
        switch information.st_mode & S_IFMT {
        case S_IFLNK:
            throw IndexedSourceSnapshotStoreError.directoryIsSymbolicLink
        case S_IFDIR:
            directoryPath = directory.path
            directoryDevice = information.st_dev
            directoryInode = information.st_ino
            accessLock = IndexedSourceSnapshotStoreLock()
        default:
            throw IndexedSourceSnapshotStoreError.directoryIsNotDirectory
        }

        let descriptor = try openDirectory()
        defer { _ = Darwin.close(descriptor) }
        guard fchmod(descriptor, S_IRWXU) == 0 else {
            throw IndexedSourceSnapshotStoreError.unavailableDirectory
        }
    }

    func fileURL(for hash: ContentHash) -> URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent(fileName(for: hash), isDirectory: false)
    }

    public func hasSnapshot(matching hash: ContentHash) -> Bool {
        accessLock.withLock {
            hasSnapshotUnlocked(matching: hash)
        }
    }

    private func hasSnapshotUnlocked(matching hash: ContentHash) -> Bool {
        guard let directory = try? openDirectory() else { return false }
        defer { _ = Darwin.close(directory) }
        let descriptor = openat(
            directory,
            fileName(for: hash),
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        return fstat(descriptor, &information) == 0
            && information.st_mode & S_IFMT == S_IFREG
    }

    public func store(_ data: Data, matching hash: ContentHash) throws {
        try accessLock.withLock {
            try storeUnlocked(data, matching: hash)
        }
    }

    private func storeUnlocked(_ data: Data, matching hash: ContentHash) throws {
        guard try Self.hash(data) == hash else {
            throw IndexedSourceSnapshotStoreError.contentHashMismatch
        }
        let directory = try openDirectory()
        defer { _ = Darwin.close(directory) }
        let name = fileName(for: hash)
        var information = stat()
        if fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) == 0 {
            guard information.st_mode & S_IFMT != S_IFLNK else {
                throw IndexedSourceSnapshotStoreError.snapshotIsSymbolicLink
            }
            guard information.st_mode & S_IFMT == S_IFREG else {
                throw IndexedSourceSnapshotStoreError.snapshotIsNotRegular
            }
        } else if errno != ENOENT {
            throw IndexedSourceSnapshotStoreError.writeFailed
        }

        let temporaryName = ".snapshot-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw IndexedSourceSnapshotStoreError.writeFailed
        }
        var removeTemporary = true
        defer {
            _ = Darwin.close(descriptor)
            if removeTemporary {
                _ = unlinkat(directory, temporaryName, 0)
            }
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw IndexedSourceSnapshotStoreError.writeFailed
        }
        guard renameat(directory, temporaryName, directory, name) == 0 else {
            throw IndexedSourceSnapshotStoreError.writeFailed
        }
        removeTemporary = false
        guard fsync(directory) == 0 else {
            throw IndexedSourceSnapshotStoreError.writeFailed
        }
    }

    public func load(
        matching hash: ContentHash,
        maximumBytes: Int = 1_024 * 1_024
    ) throws -> Data? {
        try accessLock.withLock {
            try loadUnlocked(matching: hash, maximumBytes: maximumBytes)
        }
    }

    private func loadUnlocked(
        matching hash: ContentHash,
        maximumBytes: Int
    ) throws -> Data? {
        guard maximumBytes >= 0 else {
            throw IndexedSourceSnapshotStoreError.snapshotTooLarge
        }
        let directory = try openDirectory()
        defer { _ = Darwin.close(directory) }
        let name = fileName(for: hash)
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw IndexedSourceSnapshotStoreError.snapshotIsSymbolicLink
            }
            throw IndexedSourceSnapshotStoreError.readFailed
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw IndexedSourceSnapshotStoreError.readFailed
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw IndexedSourceSnapshotStoreError.snapshotIsNotRegular
        }
        guard information.st_size >= 0, information.st_size <= maximumBytes else {
            throw IndexedSourceSnapshotStoreError.snapshotTooLarge
        }
        let data = try readData(from: descriptor, maximumBytes: maximumBytes)
        guard try Self.hash(data) == hash else {
            removeSnapshotIfUnchanged(
                named: name,
                expectedDevice: information.st_dev,
                expectedInode: information.st_ino,
                from: directory
            )
            throw IndexedSourceSnapshotStoreError.contentHashMismatch
        }
        return data
    }

    private func openDirectory() throws -> Int32 {
        let descriptor = open(
            directoryPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw IndexedSourceSnapshotStoreError.unavailableDirectory
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            _ = Darwin.close(descriptor)
            throw IndexedSourceSnapshotStoreError.unavailableDirectory
        }
        guard
            information.st_dev == directoryDevice,
            information.st_ino == directoryInode
        else {
            _ = Darwin.close(descriptor)
            throw IndexedSourceSnapshotStoreError.directoryChanged
        }
        return descriptor
    }

    private func fileName(for hash: ContentHash) -> String {
        "\(hash.hex).mdcache"
    }

    func removeSnapshotIfUnchanged(
        matching hash: ContentHash,
        expectedDevice: dev_t,
        expectedInode: ino_t
    ) throws {
        try accessLock.withLock {
            let directory = try openDirectory()
            defer { _ = Darwin.close(directory) }
            removeSnapshotIfUnchanged(
                named: fileName(for: hash),
                expectedDevice: expectedDevice,
                expectedInode: expectedInode,
                from: directory
            )
        }
    }

    private func removeSnapshotIfUnchanged(
        named name: String,
        expectedDevice: dev_t,
        expectedInode: ino_t,
        from directory: Int32
    ) {
        var current = stat()
        guard
            fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            current.st_mode & S_IFMT == S_IFREG,
            current.st_dev == expectedDevice,
            current.st_ino == expectedInode
        else {
            return
        }
        _ = unlinkat(directory, name, 0)
    }

    private func readData(from descriptor: Int32, maximumBytes: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw IndexedSourceSnapshotStoreError.readFailed
            }
            if count == 0 { return data }
            guard data.count + count <= maximumBytes else {
                throw IndexedSourceSnapshotStoreError.snapshotTooLarge
            }
            data.append(buffer, count: count)
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: written),
                    bytes.count - written
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw IndexedSourceSnapshotStoreError.writeFailed
                }
                written += count
            }
        }
    }

    private static func hash(_ data: Data) throws -> ContentHash {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try ContentHash(hex: hex)
    }
}

public actor IncrementalIndexScanner {
    private let store: LocalVaultStore
    private let repository: SQLiteIndexRepository
    private let limits: MarkdownParseLimits
    private let inventory: @Sendable () throws -> LocalVaultMarkdownInventory
    private let read: @Sendable (VaultPath, Int) throws -> LocalVaultFileSnapshot
    private let snapshots: IndexedSourceSnapshotStore?

    public init(
        root: URL,
        repository: SQLiteIndexRepository,
        limits: MarkdownParseLimits = .default,
        snapshots: IndexedSourceSnapshotStore? = nil
    ) throws {
        let store = try LocalVaultStore(root: root)
        self.store = store
        self.repository = repository
        self.limits = limits
        self.snapshots = snapshots
        inventory = { try store.markdownInventory() }
        read = { path, maximumRetainedBytes in
            try store.read(path, maximumRetainedBytes: maximumRetainedBytes)
        }
    }

    init(
        root: URL,
        repository: SQLiteIndexRepository,
        limits: MarkdownParseLimits,
        snapshots: IndexedSourceSnapshotStore? = nil,
        inventory: @escaping @Sendable () throws -> LocalVaultMarkdownInventory,
        read: @escaping @Sendable (VaultPath, Int) throws -> LocalVaultFileSnapshot
    ) throws {
        store = try LocalVaultStore(root: root)
        self.repository = repository
        self.limits = limits
        self.snapshots = snapshots
        self.inventory = inventory
        self.read = read
    }

    public func scan() async throws -> IncrementalIndexReport {
        let inventory = try inventory()
        let files = inventory.readable
        let stored = try await repository.fingerprints()
        var metadataSkipped = 0
        var hashSkipped = 0
        var indexed = 0
        var parseFailures = 0
        var unavailablePaths = inventory.temporarilyUnavailablePaths

        for file in files {
            try Task.checkCancellation()
            if let existing = stored[file.path],
                isSameMetadata(file, existing),
                snapshots?.hasSnapshot(matching: existing.contentHash) != false
            {
                unavailablePaths.remove(file.path)
                metadataSkipped += 1
                continue
            }

            let snapshot: LocalVaultFileSnapshot
            do {
                snapshot = try read(file.path, limits.maximumNoteBytes)
            } catch let error as LocalVaultStoreError
                where Self.isTemporaryFileReadError(error)
            {
                unavailablePaths.insert(file.path)
                continue
            }
            unavailablePaths.remove(file.path)
            if let existing = stored[file.path],
                existing.contentHash == snapshot.contentHash,
                try await repository.refreshMetadata(
                    for: file.path,
                    matching: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
            {
                storeSnapshotIfAvailable(snapshot)
                hashSkipped += 1
                continue
            }

            guard let data = snapshot.data else {
                try await replaceFailure(snapshot, diagnostic: "markdown.note-too-large")
                parseFailures += 1
                continue
            }
            do {
                let parsed = try MarkdownNoteParser.parse(data, at: file.path, limits: limits)
                let input = try IndexNoteInput(
                    path: file.path,
                    parsedNote: parsed,
                    contentHash: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
                try await repository.replace(input)
                storeSnapshotIfAvailable(snapshot)
                indexed += 1
            } catch let error as MarkdownParseError {
                try await replaceFailure(snapshot, diagnostic: try Self.failureDiagnostic(error))
                parseFailures += 1
            }
        }

        let currentPaths = Set(files.map(\.path))
            .union(unavailablePaths)
        let removedPaths =
            inventory.allowsRemoval
            ? stored.keys.filter { !currentPaths.contains($0) }
            : []
        for path in removedPaths {
            try Task.checkCancellation()
            try await repository.remove(path)
        }
        try await repository.resolveAllWikiLinks()
        try await repository.updateAvailability(
            unavailablePaths: unavailablePaths,
            readablePaths: Set(files.map(\.path)).subtracting(unavailablePaths),
            inventoryComplete: inventory.allowsRemoval
        )
        return IncrementalIndexReport(
            metadataSkipped: metadataSkipped,
            hashSkipped: hashSkipped,
            indexed: indexed,
            failed: parseFailures + unavailablePaths.count,
            removed: removedPaths.count
        )
    }

    public func refresh(_ path: VaultPath) async throws {
        try Task.checkCancellation()
        let snapshot = try store.read(
            path,
            maximumRetainedBytes: limits.maximumNoteBytes
        )
        guard let data = snapshot.data else {
            try await replaceFailure(snapshot, diagnostic: "markdown.note-too-large")
            return
        }
        do {
            let parsed = try MarkdownNoteParser.parse(data, at: path, limits: limits)
            try await repository.replaceAndResolveWikiLinks(
                try IndexNoteInput(
                    path: path,
                    parsedNote: parsed,
                    contentHash: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
            )
            storeSnapshotIfAvailable(snapshot)
        } catch let error as MarkdownParseError {
            try await replaceFailure(
                snapshot,
                diagnostic: try Self.failureDiagnostic(error)
            )
        }
    }

    public func rebuild() async throws -> FullIndexRebuildReport {
        let inventory = try inventory()
        let read = self.read
        let limits = self.limits
        let snapshots = self.snapshots
        return try await repository.replaceAll(
            inventory.readable,
            retaining: inventory.temporarilyUnavailablePaths,
            removeMissing: inventory.allowsRemoval
        ) { file in
            try Task.checkCancellation()
            do {
                return try Self.prepare(
                    file,
                    read: read,
                    limits: limits,
                    snapshots: snapshots
                )
            } catch let error as LocalVaultStoreError
                where Self.isTemporaryFileReadError(error)
            {
                return nil
            }
        }
    }
}

extension IncrementalIndexScanner {
    private func isSameMetadata(
        _ file: LocalVaultFileMetadata,
        _ stored: IndexedNoteFingerprint
    ) -> Bool {
        file.byteSize == stored.byteSize && file.modifiedAt == stored.modifiedAt
    }

    private func replaceFailure(
        _ snapshot: LocalVaultFileSnapshot,
        diagnostic: String
    ) async throws {
        try await repository.replaceFailure(
            at: snapshot.metadata.path,
            contentHash: snapshot.contentHash,
            modifiedAt: snapshot.metadata.modifiedAt,
            byteSize: snapshot.metadata.byteSize,
            diagnostic: diagnostic
        )
    }

    private func storeSnapshotIfAvailable(_ snapshot: LocalVaultFileSnapshot) {
        guard let data = snapshot.data else { return }
        do {
            try snapshots?.store(data, matching: snapshot.contentHash)
        } catch {
            // Reader snapshots are an optional availability optimization.
            // A full or damaged cache must never block the primary index.
        }
    }

    nonisolated private static func prepare(
        _ file: LocalVaultFileMetadata,
        read: @Sendable (VaultPath, Int) throws -> LocalVaultFileSnapshot,
        limits: MarkdownParseLimits,
        snapshots: IndexedSourceSnapshotStore?
    ) throws -> PreparedIndexEntry {
        let snapshot = try read(
            file.path,
            limits.maximumNoteBytes
        )
        guard let data = snapshot.data else {
            return failureEntry(snapshot, diagnostic: "markdown.note-too-large")
        }
        do {
            let parsed = try MarkdownNoteParser.parse(data, at: file.path, limits: limits)
            do {
                try snapshots?.store(data, matching: snapshot.contentHash)
            } catch {
                // Rebuild correctness depends on SQLite, not the optional cache.
            }
            return .note(
                try IndexNoteInput(
                    path: file.path,
                    parsedNote: parsed,
                    contentHash: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
            )
        } catch let error as MarkdownParseError {
            return failureEntry(snapshot, diagnostic: try failureDiagnostic(error))
        }
    }

    nonisolated private static func failureEntry(
        _ snapshot: LocalVaultFileSnapshot,
        diagnostic: String
    ) -> PreparedIndexEntry {
        .failure(
            path: snapshot.metadata.path,
            contentHash: snapshot.contentHash,
            modifiedAt: snapshot.metadata.modifiedAt,
            byteSize: snapshot.metadata.byteSize,
            diagnostic: diagnostic
        )
    }

    nonisolated private static func failureDiagnostic(
        _ error: MarkdownParseError
    ) throws -> String {
        switch error {
        case .noteTooLarge:
            "markdown.note-too-large"
        case .invalidUTF8:
            "markdown.invalid-utf8"
        case .invalidLimits:
            throw error
        }
    }

    nonisolated private static func isTemporaryFileReadError(
        _ error: LocalVaultStoreError
    ) -> Bool {
        switch error {
        case .unavailableFile, .fileIsNotRegular, .fileChangedDuringRead:
            true
        default:
            false
        }
    }
}
