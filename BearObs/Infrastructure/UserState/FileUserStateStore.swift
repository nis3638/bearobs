import Darwin
import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

public enum FileUserStateStoreError: Error, Equatable, Sendable {
    case invalidMetadataDirectory
    case unavailableMetadataDirectory
    case metadataDirectoryIsNotDirectory
    case metadataDirectoryIsSymbolicLink
    case metadataDirectoryChanged
    case stateFileIsNotRegular
    case stateFileTooLarge
    case invalidState
    case unsupportedSchemaVersion
    case stateReadFailed
    case stateWriteFailed
}

public actor FileUserStateStore {
    private static let stateFileName = "user-state.json"
    private static let maximumStateBytes = 1_048_576

    private let metadataPath: String
    private let metadataDevice: dev_t
    private let metadataInode: ino_t

    public init(metadataDirectory: URL) throws {
        guard metadataDirectory.isFileURL else {
            throw FileUserStateStoreError.invalidMetadataDirectory
        }

        var information = stat()
        guard lstat(metadataDirectory.path, &information) == 0 else {
            throw FileUserStateStoreError.unavailableMetadataDirectory
        }
        switch information.st_mode & S_IFMT {
        case S_IFLNK:
            throw FileUserStateStoreError.metadataDirectoryIsSymbolicLink
        case S_IFDIR:
            metadataPath = metadataDirectory.path
            metadataDevice = information.st_dev
            metadataInode = information.st_ino
        default:
            throw FileUserStateStoreError.metadataDirectoryIsNotDirectory
        }
    }

    public func favoritePaths() throws -> Set<VaultPath> {
        let directory = try openMetadataDirectory()
        defer { _ = Darwin.close(directory) }
        return try readState(from: directory).favorites
    }

    @discardableResult
    public func setFavorite(
        _ path: VaultPath,
        isFavorite: Bool
    ) throws -> Set<VaultPath> {
        let directory = try openMetadataDirectory()
        defer { _ = Darwin.close(directory) }

        var state = try readState(from: directory)
        let changed: Bool
        if isFavorite {
            changed = state.favorites.insert(path).inserted
        } else {
            changed = state.favorites.remove(path) != nil
        }
        if changed {
            try writeState(state, to: directory)
        }
        return state.favorites
    }
}

extension FileUserStateStore {
    private struct PersistedState: Codable {
        let schemaVersion: Int
        var favorites: Set<VaultPath>

        init(favorites: Set<VaultPath> = []) {
            schemaVersion = 1
            self.favorites = favorites
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case favorites
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            favorites = Set(try container.decode([VaultPath].self, forKey: .favorites))
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(favorites.sorted(), forKey: .favorites)
        }
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }

    private func openMetadataDirectory() throws -> Int32 {
        let descriptor = open(
            metadataPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw FileUserStateStoreError.unavailableMetadataDirectory
        }
        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw FileUserStateStoreError.unavailableMetadataDirectory
            }
            guard
                information.st_dev == metadataDevice,
                information.st_ino == metadataInode
            else {
                throw FileUserStateStoreError.metadataDirectoryChanged
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private func readState(from directory: Int32) throws -> PersistedState {
        let descriptor = openat(
            directory,
            Self.stateFileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 {
            if errno == ENOENT { return PersistedState() }
            if errno == ELOOP {
                throw FileUserStateStoreError.stateFileIsNotRegular
            }
            throw FileUserStateStoreError.stateReadFailed
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw FileUserStateStoreError.stateReadFailed
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw FileUserStateStoreError.stateFileIsNotRegular
        }
        guard information.st_size <= Self.maximumStateBytes else {
            throw FileUserStateStoreError.stateFileTooLarge
        }

        let data = try readData(from: descriptor)
        let decoder = JSONDecoder()
        let header: SchemaHeader
        do {
            header = try decoder.decode(SchemaHeader.self, from: data)
        } catch {
            throw FileUserStateStoreError.invalidState
        }
        guard header.schemaVersion == 1 else {
            throw FileUserStateStoreError.unsupportedSchemaVersion
        }
        do {
            return try decoder.decode(PersistedState.self, from: data)
        } catch {
            throw FileUserStateStoreError.invalidState
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
                throw FileUserStateStoreError.stateReadFailed
            }
            if count == 0 { return data }
            guard data.count + count <= Self.maximumStateBytes else {
                throw FileUserStateStoreError.stateFileTooLarge
            }
            data.append(buffer, count: count)
        }
    }

    private func writeState(_ state: PersistedState, to directory: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw FileUserStateStoreError.stateWriteFailed
        }

        let temporaryName = ".user-state-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw FileUserStateStoreError.stateWriteFailed
        }

        var shouldRemoveTemporaryFile = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemoveTemporaryFile {
                _ = unlinkat(directory, temporaryName, 0)
            }
        }

        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw FileUserStateStoreError.stateWriteFailed
        }
        guard
            renameat(
                directory,
                temporaryName,
                directory,
                Self.stateFileName
            ) == 0
        else {
            throw FileUserStateStoreError.stateWriteFailed
        }
        shouldRemoveTemporaryFile = false
        guard fsync(directory) == 0 else {
            throw FileUserStateStoreError.stateWriteFailed
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
                    throw FileUserStateStoreError.stateWriteFailed
                }
                written += count
            }
        }
    }
}
