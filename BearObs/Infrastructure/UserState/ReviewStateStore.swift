import Darwin
import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

/// 回顾状态持久化的失败原因（REQ-005 T2）。
public enum ReviewStateStoreError: Error, Equatable, Sendable {
    case invalidMetadataDirectory
    case unavailableMetadataDirectory
    case metadataDirectoryIsNotDirectory
    case metadataDirectoryIsSymbolicLink
    case metadataDirectoryChanged
    case stateFileIsNotRegular
    case stateFileTooLarge
    case stateReadFailed
    case stateWriteFailed
    case invalidState
    case vaultMismatch
}

/// 某 Vault 的回顾状态（REQ-005 FR-005.1）：规则与当日批次，两者皆缺即空状态。
///
/// 状态可随时删除重建：删除后笔记仍可浏览，回顾在下次打开时重新抽取。
public struct ReviewState: Equatable, Sendable {
    public let rule: ReviewRule?
    public let batch: ReviewBatch?

    public init(rule: ReviewRule? = nil, batch: ReviewBatch? = nil) {
        self.rule = rule
        self.batch = batch
    }
}

/// 按 Vault 持久化回顾规则与当日批次（REQ-005 T2）。
///
/// 状态文件是元数据目录下与 `user-state.json` 并列的 `review-state.json`，
/// 每个 Vault 一份。目录定位复用 `FileUserStateStore` 已有的方式，由调用方
/// 传入元数据目录，不新建第二套路径规则。本类型只读写该元数据目录，不触碰
/// Vault 笔记文件（FR-005.1）。写入先编码再落临时文件、原子替换，编码失败
/// 时返回明确错误，不写半截文件；读取时文件不存在返回空状态，不视为错误。
public actor ReviewStateStore {
    private static let stateFileName = "review-state.json"
    private static let maximumStateBytes = 1_048_576

    private let metadataPath: String
    private let metadataDevice: dev_t
    private let metadataInode: ino_t

    public init(metadataDirectory: URL) throws {
        guard metadataDirectory.isFileURL else {
            throw ReviewStateStoreError.invalidMetadataDirectory
        }

        var information = stat()
        guard lstat(metadataDirectory.path, &information) == 0 else {
            throw ReviewStateStoreError.unavailableMetadataDirectory
        }
        switch information.st_mode & S_IFMT {
        case S_IFLNK:
            throw ReviewStateStoreError.metadataDirectoryIsSymbolicLink
        case S_IFDIR:
            metadataPath = metadataDirectory.path
            metadataDevice = information.st_dev
            metadataInode = information.st_ino
        default:
            throw ReviewStateStoreError.metadataDirectoryIsNotDirectory
        }
    }

    /// 读取该 Vault 的规则与批次；文件不存在返回空状态，不视为错误。
    ///
    /// 批次属于其他 Vault 时不返回（FR-005.3：切换 Vault 不复用上一本
    /// Vault 的规则与批次）。
    public func load(vaultID: UUID) throws -> ReviewState {
        let directory = try openMetadataDirectory()
        defer { _ = Darwin.close(directory) }
        let persisted = try readState(from: directory)
        return ReviewState(
            rule: persisted.rule,
            batch: visibleBatch(persisted.batch, for: vaultID)
        )
    }

    /// 保存规则。已存在的批次保留在盘上，由调用方按「批次规则与当前规则
    /// 相等且日期为今天」判定复用，规则变化即整条作废重抽（REQ-005 §9.4）。
    @discardableResult
    public func save(vaultID: UUID, rule: ReviewRule) throws -> ReviewState {
        let directory = try openMetadataDirectory()
        defer { _ = Darwin.close(directory) }
        var persisted = try readState(from: directory)
        persisted.rule = rule
        try writeState(persisted, to: directory)
        return ReviewState(
            rule: rule,
            batch: visibleBatch(persisted.batch, for: vaultID)
        )
    }

    /// 保存当日批次。批次属于其他 Vault 时拒绝写入。
    @discardableResult
    public func save(vaultID: UUID, batch: ReviewBatch) throws -> ReviewState {
        guard batch.vaultID == vaultID else {
            throw ReviewStateStoreError.vaultMismatch
        }
        let directory = try openMetadataDirectory()
        defer { _ = Darwin.close(directory) }
        var persisted = try readState(from: directory)
        persisted.batch = batch
        try writeState(persisted, to: directory)
        return ReviewState(rule: persisted.rule, batch: batch)
    }

    /// 删除该 Vault 的回顾状态；文件本就不存在时为空操作。
    public func delete(vaultID: UUID) throws {
        let directory = try openMetadataDirectory()
        defer { _ = Darwin.close(directory) }
        if unlinkat(directory, Self.stateFileName, 0) != 0 {
            guard errno == ENOENT else {
                throw ReviewStateStoreError.stateWriteFailed
            }
        }
    }

    /// 其他 Vault 的批次绝不经本方法外泄（两个 Vault 的状态互不读取）。
    private func visibleBatch(
        _ batch: ReviewBatch?,
        for vaultID: UUID
    ) -> ReviewBatch? {
        guard let batch, batch.vaultID == vaultID else { return nil }
        return batch
    }
}

extension ReviewStateStore {
    private struct PersistedState: Codable {
        var rule: ReviewRule?
        var batch: ReviewBatch?
    }

    private func openMetadataDirectory() throws -> Int32 {
        let descriptor = open(
            metadataPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw ReviewStateStoreError.unavailableMetadataDirectory
        }
        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw ReviewStateStoreError.unavailableMetadataDirectory
            }
            guard
                information.st_dev == metadataDevice,
                information.st_ino == metadataInode
            else {
                throw ReviewStateStoreError.metadataDirectoryChanged
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
                throw ReviewStateStoreError.stateFileIsNotRegular
            }
            throw ReviewStateStoreError.stateReadFailed
        }
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw ReviewStateStoreError.stateReadFailed
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw ReviewStateStoreError.stateFileIsNotRegular
        }
        guard information.st_size <= Self.maximumStateBytes else {
            throw ReviewStateStoreError.stateFileTooLarge
        }

        let data = try readData(from: descriptor)
        do {
            return try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            throw ReviewStateStoreError.invalidState
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
                throw ReviewStateStoreError.stateReadFailed
            }
            if count == 0 { return data }
            guard data.count + count <= Self.maximumStateBytes else {
                throw ReviewStateStoreError.stateFileTooLarge
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
            throw ReviewStateStoreError.stateWriteFailed
        }

        let temporaryName = ".review-state-\(UUID().uuidString).tmp"
        let descriptor = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ReviewStateStoreError.stateWriteFailed
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
            throw ReviewStateStoreError.stateWriteFailed
        }
        guard
            renameat(
                directory,
                temporaryName,
                directory,
                Self.stateFileName
            ) == 0
        else {
            throw ReviewStateStoreError.stateWriteFailed
        }
        shouldRemoveTemporaryFile = false
        guard fsync(directory) == 0 else {
            throw ReviewStateStoreError.stateWriteFailed
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
                    throw ReviewStateStoreError.stateWriteFailed
                }
                written += count
            }
        }
    }
}
