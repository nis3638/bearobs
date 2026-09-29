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
        public static func make(for root: URL) throws -> VaultSelection {
            guard root.isFileURL else {
                throw VaultSelectionStoreError.invalidVaultURL
            }
            let bookmark = try root.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return VaultSelection(bookmarkData: bookmark)
        }

        public func resolve() throws -> (url: URL, isStale: Bool) {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
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

public struct VaultSelectionStore: Sendable {
    private static let fileName = "selected-vault.json"
    private static let maximumBytes = 1_048_576
    private let directory: URL

    public init(directory: URL) throws {
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
        default:
            throw VaultSelectionStoreError.directoryIsNotDirectory
        }
    }

    public func load() throws -> VaultSelection? {
        let file = directory.appendingPathComponent(Self.fileName)
        var information = stat()
        guard lstat(file.path, &information) == 0 else {
            if errno == ENOENT { return nil }
            throw VaultSelectionStoreError.selectionReadFailed
        }
        guard information.st_mode & S_IFMT != S_IFLNK else {
            throw VaultSelectionStoreError.selectionFileIsSymbolicLink
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw VaultSelectionStoreError.selectionFileIsNotRegular
        }
        guard information.st_size <= Self.maximumBytes else {
            throw VaultSelectionStoreError.selectionFileTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: file, options: [.mappedIfSafe])
        } catch {
            throw VaultSelectionStoreError.selectionReadFailed
        }
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

        let file = directory.appendingPathComponent(Self.fileName)
        var information = stat()
        if lstat(file.path, &information) == 0,
            information.st_mode & S_IFMT == S_IFLNK
        {
            throw VaultSelectionStoreError.selectionFileIsSymbolicLink
        }
        do {
            try data.write(to: file, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: file.path
            )
        } catch {
            throw VaultSelectionStoreError.selectionWriteFailed
        }
    }
}

private struct PersistedSelection: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let bookmarkData: Data
}
