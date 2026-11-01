import Darwin
import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public struct VaultSelection: Codable, Equatable, Sendable {
    public let id: UUID
    public let bookmarkData: Data

    public init(id: UUID = UUID(), bookmarkData: Data) {
        self.id = id
        self.bookmarkData = bookmarkData
    }

    #if os(macOS) || os(iOS)
        /// Recorded platform seam (REQ-004 §7, ADR-010): `.withSecurityScope`
        /// is a macOS bookmark option. iOS grants access scope to
        /// document-picker URLs directly, so bookmarks are created and
        /// resolved without options there and access is restored through
        /// `startAccessingSecurityScopedResource` on the resolved URL.
        private static var bookmarkCreationOptions: URL.BookmarkCreationOptions {
            #if os(macOS)
                [.withSecurityScope]
            #else
                []
            #endif
        }

        private static var bookmarkResolutionOptions: URL.BookmarkResolutionOptions {
            #if os(macOS)
                [.withSecurityScope]
            #else
                []
            #endif
        }

        public static func make(for root: URL) throws -> VaultSelection {
            guard root.isFileURL else {
                throw VaultSelectionStoreError.invalidVaultURL
            }
            let bookmark = try root.bookmarkData(
                options: bookmarkCreationOptions,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return VaultSelection(bookmarkData: bookmark)
        }

        public func resolve() throws -> (url: URL, isStale: Bool) {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: Self.bookmarkResolutionOptions,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.isFileURL else {
                throw VaultSelectionStoreError.invalidVaultURL
            }
            return (url, isStale)
        }
    #endif
}

public enum VaultSelectionStoreError: Error, Equatable, Sendable {
    case invalidDirectory
    case unavailableDirectory
    case directoryIsSymbolicLink
    case directoryIsNotDirectory
    case selectionFileIsSymbolicLink
    case selectionFileIsNotRegular
    case selectionFileTooLarge
    case invalidSelection
    case unsupportedSchemaVersion
    case selectionReadFailed
    case selectionWriteFailed
    case invalidVaultURL
}

enum VaultSelectionSaveCheckpoint: Equatable, Sendable {
    case beforePermissions
    case beforeFileSync
    case beforeRename
}

public struct VaultSelectionStore: Sendable {
    private static let fileName = "selected-vault.json"
    private static let maximumBytes = 1_048_576
    private let directory: URL
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private let saveCheckpoint: @Sendable (VaultSelectionSaveCheckpoint) throws -> Void

    public init(directory: URL) throws {
        try self.init(directory: directory, saveCheckpoint: { _ in })
    }

    init(
        directory: URL,
        saveCheckpoint: @escaping @Sendable (VaultSelectionSaveCheckpoint) throws -> Void
    ) throws {
        guard directory.isFileURL else {
            throw VaultSelectionStoreError.invalidDirectory
        }
        var information = stat()
        guard lstat(directory.path, &information) == 0 else {
            throw VaultSelectionStoreError.unavailableDirectory
        }
        switch information.st_mode & S_IFMT {
        case S_IFLNK:
            throw VaultSelectionStoreError.directoryIsSymbolicLink
        case S_IFDIR:
            self.directory = directory
            directoryDevice = information.st_dev
            directoryInode = information.st_ino
            self.saveCheckpoint = saveCheckpoint
        default:
            throw VaultSelectionStoreError.directoryIsNotDirectory
        }
    }

    public func load() throws -> VaultSelection? {
        let directoryDescriptor = try openVerifiedDirectory(
            error: .selectionReadFailed
        )
        defer { _ = Darwin.close(directoryDescriptor) }

        let descriptor = openat(
            directoryDescriptor,
            Self.fileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP {
                throw VaultSelectionStoreError.selectionFileIsSymbolicLink
            }
            throw VaultSelectionStoreError.selectionReadFailed
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw VaultSelectionStoreError.selectionReadFailed
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw VaultSelectionStoreError.selectionFileIsNotRegular
        }
        guard information.st_size >= 0, information.st_size <= Self.maximumBytes else {
            throw VaultSelectionStoreError.selectionFileTooLarge
        }

        let data = try readData(from: descriptor)
        let persisted: PersistedSelection
        do {
            persisted = try JSONDecoder().decode(PersistedSelection.self, from: data)
        } catch {
            throw VaultSelectionStoreError.invalidSelection
        }
        guard persisted.schemaVersion == 1 else {
            throw VaultSelectionStoreError.unsupportedSchemaVersion
        }
        guard !persisted.bookmarkData.isEmpty else {
            throw VaultSelectionStoreError.invalidSelection
        }
        return VaultSelection(id: persisted.id, bookmarkData: persisted.bookmarkData)
    }

    public func save(_ selection: VaultSelection) throws {
        guard !selection.bookmarkData.isEmpty else {
            throw VaultSelectionStoreError.invalidSelection
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(
                PersistedSelection(
                    schemaVersion: 1,
                    id: selection.id,
                    bookmarkData: selection.bookmarkData
                )
            )
        } catch {
            throw VaultSelectionStoreError.selectionWriteFailed
        }

        try writeAtomically(data)
    }

    private func writeAtomically(_ data: Data) throws {
        let directoryDescriptor = try openVerifiedDirectory(
            error: .selectionWriteFailed
        )
        defer { _ = Darwin.close(directoryDescriptor) }

        var destinationInformation = stat()
        if fstatat(
            directoryDescriptor,
            Self.fileName,
            &destinationInformation,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            destinationInformation.st_mode & S_IFMT == S_IFLNK
        {
            throw VaultSelectionStoreError.selectionFileIsSymbolicLink
        }

        let temporaryName = ".selected-vault-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw VaultSelectionStoreError.selectionWriteFailed
        }

        var shouldRemoveTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
        }

        do {
            try writeAll(data, to: descriptor)
            try saveCheckpoint(.beforePermissions)
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw VaultSelectionStoreError.selectionWriteFailed
            }
            try saveCheckpoint(.beforeFileSync)
            guard fsync(descriptor) == 0 else {
                throw VaultSelectionStoreError.selectionWriteFailed
            }
            try saveCheckpoint(.beforeRename)
            guard
                renameat(
                    directoryDescriptor,
                    temporaryName,
                    directoryDescriptor,
                    Self.fileName
                ) == 0
            else {
                throw VaultSelectionStoreError.selectionWriteFailed
            }
            // The rename is the commit point and deliberately the last
            // operation that may report failure. A directory fsync improves
            // crash durability, but once rename succeeds, reporting a later
            // sync failure would make the UI retain Vault A while an ordinary
            // next launch restores Vault B.
            shouldRemoveTemporaryFile = false
            _ = fsync(directoryDescriptor)
        } catch let error as VaultSelectionStoreError {
            throw error
        } catch {
            throw VaultSelectionStoreError.selectionWriteFailed
        }
    }

    private func openVerifiedDirectory(
        error failure: VaultSelectionStoreError
    ) throws -> Int32 {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw failure }
        do {
            var information = stat()
            guard
                fstat(descriptor, &information) == 0,
                information.st_dev == directoryDevice,
                information.st_ino == directoryInode
            else {
                throw failure
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw failure
        }
    }

    private func readData(from descriptor: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw VaultSelectionStoreError.selectionReadFailed
            }
            if count == 0 { return data }
            guard data.count + count <= Self.maximumBytes else {
                throw VaultSelectionStoreError.selectionFileTooLarge
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
                    throw VaultSelectionStoreError.selectionWriteFailed
                }
                written += count
            }
        }
    }
}

private struct PersistedSelection: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let bookmarkData: Data
}
