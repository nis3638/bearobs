import CryptoKit
import Darwin
import Foundation

public enum RecoveryJournalState: String, Codable, Equatable, Sendable {
    case cleanupPending
    case cleanupAuthorized
    case manualReview
}

public enum RecoveryResourceKind: String, Codable, Equatable, Sendable {
    case file
    case collection
}

/// A single, explicitly registered synthetic resource.
///
/// Only canonical relative paths and SHA-256 digests are persisted. Remote
/// bodies and raw entity-tags are deliberately absent from this schema.
public struct ResourceRecord: Codable, Equatable, Sendable {
    public let path: String
    public let kind: RecoveryResourceKind
    public let expectedBodyHashes: [String]
    public let etagHash: String?

    public init(
        path: String,
        kind: RecoveryResourceKind,
        expectedBodyHashes: [String],
        etagHash: String?
    ) throws {
        try JournalValidation.validateResource(
            path: path,
            kind: kind,
            expectedBodyHashes: expectedBodyHashes,
            etagHash: etagHash
        )
        self.path = path
        self.kind = kind
        self.expectedBodyHashes = expectedBodyHashes
        self.etagHash = etagHash
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(
            in: decoder,
            allowed: ["path", "kind", "expectedBodyHashes", "etagHash"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            path: container.decode(String.self, forKey: .path),
            kind: container.decode(RecoveryResourceKind.self, forKey: .kind),
            expectedBodyHashes: container.decode([String].self, forKey: .expectedBodyHashes),
            etagHash: container.decodeIfPresent(String.self, forKey: .etagHash)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(kind, forKey: .kind)
        try container.encode(expectedBodyHashes, forKey: .expectedBodyHashes)
        try container.encodeIfPresent(etagHash, forKey: .etagHash)
    }

    /// Returns whether `body` has one of the explicitly registered digests.
    public func matchesExpectedBody(_ body: Data) -> Bool {
        guard kind == .file else { return false }
        return expectedBodyHashes.contains(JournalDigest.sha256(body))
    }

    /// Compares a strong ETag without exposing or persisting its raw value.
    /// A match requires both a registered digest and a candidate strong ETag.
    public func matchesETag(_ etag: StrongETag?) -> Bool {
        guard let etagHash, let etag else { return false }
        return JournalDigest.sha256(Data(etag.headerValue.utf8)) == etagHash
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case kind
        case expectedBodyHashes
        case etagHash
    }
}

/// Complete cleanup intent for one verifier run.
public struct RecoveryRecord: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let state: RecoveryJournalState
    public let scopeHash: String
    public let runDirectory: String
    public let resources: [ResourceRecord]

    public init(
        formatVersion: Int,
        state: RecoveryJournalState,
        scopeHash: String,
        runDirectory: String,
        resources: [ResourceRecord]
    ) throws {
        try JournalValidation.validateRecord(
            formatVersion: formatVersion,
            scopeHash: scopeHash,
            runDirectory: runDirectory,
            resources: resources
        )
        self.formatVersion = formatVersion
        self.state = state
        self.scopeHash = scopeHash
        self.runDirectory = runDirectory
        self.resources = resources
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownKeys(
            in: decoder,
            allowed: ["formatVersion", "state", "scopeHash", "runDirectory", "resources"]
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            formatVersion: container.decode(Int.self, forKey: .formatVersion),
            state: container.decode(RecoveryJournalState.self, forKey: .state),
            scopeHash: container.decode(String.self, forKey: .scopeHash),
            runDirectory: container.decode(String.self, forKey: .runDirectory),
            resources: container.decode([ResourceRecord].self, forKey: .resources)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(state, forKey: .state)
        try container.encode(scopeHash, forKey: .scopeHash)
        try container.encode(runDirectory, forKey: .runDirectory)
        try container.encode(resources, forKey: .resources)
    }

    public func matchesScopeIdentifier(_ scopeIdentifier: String) -> Bool {
        scopeHash == JournalDigest.sha256(Data(scopeIdentifier.utf8))
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case state
        case scopeHash
        case runDirectory
        case resources
    }
}

public enum RecoveryJournalError: Error, Equatable, Sendable {
    case invalidLocation
    case directoryUnavailable
    case insecureDirectory
    case journalAlreadyExists
    case journalMissing
    case insecureJournalFile
    case invalidRecord
    case invalidState
    case duplicateResource
    case resourceOutsideRunDirectory
    case limitExceeded
    case runInProgress
    case ioFailure
}

final class RecoveryJournalLease: @unchecked Sendable {
    private let descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

/// Private, crash-safe storage for explicitly registered cleanup intent.
public final class RecoveryJournal: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Acquires the process-wide lease for a complete verify/recover lifecycle.
    /// The caller must retain the returned object until all remote work ends.
    func acquireRunLease() throws -> RecoveryJournalLease {
        lock.lock()
        defer { lock.unlock() }

        let location = try validatedLocation()
        _ = try prepareDirectory(
            location.directory,
            createIfMissing: true,
            repairMode: false
        )
        let descriptor = try openSecureLockFile(at: location.leaseFile)
        do {
            try lockDescriptor(descriptor, operation: LOCK_EX | LOCK_NB)
            return RecoveryJournalLease(descriptor: descriptor)
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    /// Starts a new run. An existing journal is never overwritten.
    public func start(runDirectory: VerifierPath, scopeIdentifier: String) throws {
        try withLock(repairDirectoryMode: true) {
            let location = try validatedLocation()
            _ = try prepareDirectory(location.directory, createIfMissing: true, repairMode: true)
            let record = try RecoveryRecord(
                formatVersion: JournalLimits.formatVersion,
                state: .cleanupPending,
                scopeHash: JournalDigest.sha256(Data(scopeIdentifier.utf8)),
                runDirectory: runDirectory.percentEncodedRelativePath,
                resources: []
            )
            try publishNew(try encode(record), at: location)
        }
    }

    /// Adds exactly one resource to the cleanup allowlist before mutation.
    public func registerIntent(
        path: VerifierPath,
        kind: RecoveryResourceKind,
        expectedBodies: [Data],
        etag: StrongETag?
    ) throws {
        let hashes = try expectedBodyHashes(expectedBodies, kind: kind)
        let resource = try ResourceRecord(
            path: path.percentEncodedRelativePath,
            kind: kind,
            expectedBodyHashes: hashes,
            etagHash: etag.map { JournalDigest.sha256(Data($0.headerValue.utf8)) }
        )

        try withLock {
            guard let record = try loadUnlocked() else {
                throw RecoveryJournalError.journalMissing
            }
            guard record.state == .cleanupPending else {
                throw RecoveryJournalError.invalidState
            }
            guard !record.resources.contains(where: { $0.path == resource.path }) else {
                throw RecoveryJournalError.duplicateResource
            }
            guard record.resources.count < JournalLimits.maximumResources else {
                throw RecoveryJournalError.limitExceeded
            }

            let updated = try RecoveryRecord(
                formatVersion: record.formatVersion,
                state: record.state,
                scopeHash: record.scopeHash,
                runDirectory: record.runDirectory,
                resources: record.resources + [resource]
            )
            try replaceExisting(try encode(updated), at: try validatedLocation())
        }
    }

    public func load() throws -> RecoveryRecord? {
        try withLock { try loadUnlocked() }
    }

    /// Records that this run proved stale `If-Match` DELETE returns 412 and
    /// preserves the resource. Automatic deletion is forbidden before this.
    public func authorizeCleanup() throws {
        try withLock {
            guard let record = try loadUnlocked() else {
                throw RecoveryJournalError.journalMissing
            }
            guard record.state == .cleanupPending, !record.resources.isEmpty else {
                throw RecoveryJournalError.invalidState
            }
            let updated = try RecoveryRecord(
                formatVersion: record.formatVersion,
                state: .cleanupAuthorized,
                scopeHash: record.scopeHash,
                runDirectory: record.runDirectory,
                resources: record.resources
            )
            try replaceExisting(try encode(updated), at: try validatedLocation())
        }
    }

    /// Safely checks body identity for a registered path. Missing journals,
    /// manual-review state, and unregistered paths all return false.
    public func matchesExpectedBody(_ body: Data, for path: VerifierPath) throws -> Bool {
        guard let resource = try activeResource(for: path) else { return false }
        return resource.matchesExpectedBody(body)
    }

    /// Safely checks ETag identity for a registered path without returning the
    /// stored digest or consuming a raw ETag from disk.
    public func matchesETag(_ etag: StrongETag?, for path: VerifierPath) throws -> Bool {
        guard let resource = try activeResource(for: path) else { return false }
        return resource.matchesETag(etag)
    }

    public func markManualReview() throws {
        try withLock {
            guard let record = try loadUnlocked() else {
                throw RecoveryJournalError.journalMissing
            }
            guard record.state != .manualReview else { return }
            let updated = try RecoveryRecord(
                formatVersion: record.formatVersion,
                state: .manualReview,
                scopeHash: record.scopeHash,
                runDirectory: record.runDirectory,
                resources: record.resources
            )
            try replaceExisting(try encode(updated), at: try validatedLocation())
        }
    }

    /// Removes only this configured journal file. It never scans the directory.
    public func clear() throws {
        try withLock {
            let location = try validatedLocation()
            guard
                try prepareDirectory(
                    location.directory,
                    createIfMissing: false,
                    repairMode: false
                )
            else {
                return
            }
            guard try verifyJournalIfPresent(location.file) else { return }
            guard location.file.withCString({ unlink($0) }) == 0 else {
                throw RecoveryJournalError.ioFailure
            }
            try synchronizeDirectory(location.directory)
        }
    }

    private func activeResource(for path: VerifierPath) throws -> ResourceRecord? {
        guard let record = try load(), record.state != .manualReview else { return nil }
        let encodedPath = path.percentEncodedRelativePath
        return record.resources.first { $0.path == encodedPath }
    }

    private func loadUnlocked() throws -> RecoveryRecord? {
        let location = try validatedLocation()
        guard
            try prepareDirectory(
                location.directory,
                createIfMissing: false,
                repairMode: false
            )
        else {
            return nil
        }
        guard let data = try readJournal(at: location.file) else { return nil }

        do {
            return try JSONDecoder().decode(RecoveryRecord.self, from: data)
        } catch let error as RecoveryJournalError {
            throw error
        } catch {
            throw RecoveryJournalError.invalidRecord
        }
    }

    private func expectedBodyHashes(
        _ bodies: [Data],
        kind: RecoveryResourceKind
    ) throws -> [String] {
        switch kind {
        case .file:
            guard !bodies.isEmpty else { throw RecoveryJournalError.invalidRecord }
        case .collection:
            guard bodies.isEmpty else { throw RecoveryJournalError.invalidRecord }
        }
        guard bodies.count <= JournalLimits.maximumExpectedBodies else {
            throw RecoveryJournalError.limitExceeded
        }
        guard bodies.allSatisfy({ $0.count <= JournalLimits.maximumExpectedBodyBytes }) else {
            throw RecoveryJournalError.limitExceeded
        }

        var seen = Set<String>()
        return bodies.compactMap { body in
            let digest = JournalDigest.sha256(body)
            return seen.insert(digest).inserted ? digest : nil
        }
    }

    private func encode(_ record: RecoveryRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(record)
            guard data.count <= JournalLimits.maximumJournalBytes else {
                throw RecoveryJournalError.limitExceeded
            }
            return data
        } catch let error as RecoveryJournalError {
            throw error
        } catch {
            throw RecoveryJournalError.invalidRecord
        }
    }

    private func validatedLocation() throws -> JournalLocation {
        guard fileURL.isFileURL else { throw RecoveryJournalError.invalidLocation }
        let standardized = fileURL.standardizedFileURL
        let file = standardized.path
        let directory = standardized.deletingLastPathComponent().path
        let name = standardized.lastPathComponent
        guard file.hasPrefix("/"), directory.hasPrefix("/"), directory != file,
            !name.isEmpty, name != ".", name != "..",
            !file.utf8.contains(0), !directory.utf8.contains(0)
        else {
            throw RecoveryJournalError.invalidLocation
        }
        return JournalLocation(file: file, directory: directory, name: name)
    }

    private func withLock<T>(
        repairDirectoryMode: Bool = false,
        _ operation: () throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let location = try validatedLocation()
        _ = try prepareDirectory(
            location.directory,
            createIfMissing: true,
            repairMode: repairDirectoryMode
        )
        return try withAdvisoryLock(at: location.lockFile, operation)
    }
}

private struct JournalLocation {
    let file: String
    let directory: String
    let name: String

    var lockFile: String {
        directory + "/." + name + ".lock"
    }

    var leaseFile: String {
        directory + "/." + name + ".run.lock"
    }
}

private enum JournalLimits {
    static let formatVersion = 3
    static let maximumJournalBytes = 1_048_576
    static let maximumResources = 512
    static let maximumExpectedBodies = 16
    static let maximumExpectedBodyBytes = 16 * 1_048_576
    static let maximumEncodedPathBytes = 4_096
}

private enum JournalValidation {
    static func validateRecord(
        formatVersion: Int,
        scopeHash: String,
        runDirectory: String,
        resources: [ResourceRecord]
    ) throws {
        guard formatVersion == JournalLimits.formatVersion else {
            throw RecoveryJournalError.invalidRecord
        }
        guard resources.count <= JournalLimits.maximumResources else {
            throw RecoveryJournalError.limitExceeded
        }
        guard isDigest(scopeHash) else {
            throw RecoveryJournalError.invalidRecord
        }
        _ = try canonicalPath(runDirectory)
        let childPrefix = runDirectory + "/"
        var paths = Set<String>()
        for resource in resources {
            try validateResource(
                path: resource.path,
                kind: resource.kind,
                expectedBodyHashes: resource.expectedBodyHashes,
                etagHash: resource.etagHash
            )
            guard resource.path == runDirectory || resource.path.hasPrefix(childPrefix) else {
                throw RecoveryJournalError.resourceOutsideRunDirectory
            }
            guard paths.insert(resource.path).inserted else {
                throw RecoveryJournalError.duplicateResource
            }
        }
    }

    static func validateResource(
        path: String,
        kind: RecoveryResourceKind,
        expectedBodyHashes: [String],
        etagHash: String?
    ) throws {
        _ = try canonicalPath(path)
        guard expectedBodyHashes.count <= JournalLimits.maximumExpectedBodies else {
            throw RecoveryJournalError.limitExceeded
        }
        switch kind {
        case .file:
            guard !expectedBodyHashes.isEmpty else {
                throw RecoveryJournalError.invalidRecord
            }
        case .collection:
            guard expectedBodyHashes.isEmpty else {
                throw RecoveryJournalError.invalidRecord
            }
        }
        guard Set(expectedBodyHashes).count == expectedBodyHashes.count,
            expectedBodyHashes.allSatisfy(isDigest(_:)),
            etagHash.map(isDigest(_:)) ?? true
        else {
            throw RecoveryJournalError.invalidRecord
        }
    }

    private static func canonicalPath(_ value: String) throws -> VerifierPath {
        guard value.utf8.count <= JournalLimits.maximumEncodedPathBytes else {
            throw RecoveryJournalError.limitExceeded
        }
        do {
            let path = try VerifierPath(percentEncodedRelativePath: value)
            guard path.percentEncodedRelativePath == value else {
                throw RecoveryJournalError.invalidRecord
            }
            return path
        } catch let error as RecoveryJournalError {
            throw error
        } catch {
            throw RecoveryJournalError.invalidRecord
        }
    }

    private static func isDigest(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}

private enum JournalDigest {
    static func sha256(_ data: Data) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            encoded.append(digits[Int(byte >> 4)])
            encoded.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func rejectUnknownKeys(in decoder: any Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    guard container.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unexpected journal field")
        )
    }
}

private func prepareDirectory(
    _ path: String,
    createIfMissing: Bool,
    repairMode: Bool
) throws -> Bool {
    var metadata = stat()
    var result = path.withCString { lstat($0, &metadata) }
    if result != 0 {
        let failure = errno
        guard failure == ENOENT else { throw RecoveryJournalError.directoryUnavailable }
        guard createIfMissing else { return false }
        result = path.withCString { mkdir($0, mode_t(0o700)) }
        if result != 0, errno != EEXIST {
            throw RecoveryJournalError.directoryUnavailable
        }
        guard path.withCString({ lstat($0, &metadata) }) == 0 else {
            throw RecoveryJournalError.directoryUnavailable
        }
    }

    guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
        metadata.st_uid == geteuid()
    else {
        throw RecoveryJournalError.insecureDirectory
    }
    let permissions = metadata.st_mode & mode_t(0o777)
    if repairMode, permissions != mode_t(0o700) {
        guard path.withCString({ chmod($0, mode_t(0o700)) }) == 0 else {
            throw RecoveryJournalError.insecureDirectory
        }
    } else if permissions != mode_t(0o700) {
        throw RecoveryJournalError.insecureDirectory
    }
    return true
}

/// Serializes read-modify-write cycles across independent journal instances
/// and processes. The lock file contains no journal data and may persist after
/// the journal itself is cleared.
private func withAdvisoryLock<T>(
    at path: String,
    _ operation: () throws -> T
) throws -> T {
    let descriptor = try openSecureLockFile(at: path)
    defer { _ = close(descriptor) }

    try lockDescriptor(descriptor, operation: LOCK_EX)
    defer { _ = flock(descriptor, LOCK_UN) }
    return try operation()
}

private func openSecureLockFile(at path: String) throws -> Int32 {
    let descriptor = path.withCString {
        open($0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    }
    guard descriptor >= 0 else { throw RecoveryJournalError.insecureJournalFile }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
        _ = close(descriptor)
        throw RecoveryJournalError.ioFailure
    }
    guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        metadata.st_uid == geteuid(),
        metadata.st_nlink == 1,
        (metadata.st_mode & mode_t(0o777)) == mode_t(0o600)
    else {
        _ = close(descriptor)
        throw RecoveryJournalError.insecureJournalFile
    }
    return descriptor
}

private func lockDescriptor(_ descriptor: Int32, operation: Int32) throws {
    while flock(descriptor, operation) != 0 {
        if errno == EINTR { continue }
        if operation & LOCK_NB != 0, errno == EWOULDBLOCK || errno == EAGAIN {
            throw RecoveryJournalError.runInProgress
        }
        throw RecoveryJournalError.ioFailure
    }
}

private func verifyJournalIfPresent(_ path: String) throws -> Bool {
    var metadata = stat()
    guard path.withCString({ lstat($0, &metadata) }) == 0 else {
        if errno == ENOENT { return false }
        throw RecoveryJournalError.insecureJournalFile
    }
    try validateJournalMetadata(metadata)
    return true
}

private func validateJournalMetadata(_ metadata: stat) throws {
    guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        metadata.st_uid == geteuid(),
        metadata.st_nlink == 1,
        (metadata.st_mode & mode_t(0o777)) == mode_t(0o600),
        metadata.st_size >= 0,
        metadata.st_size <= off_t(JournalLimits.maximumJournalBytes)
    else {
        throw RecoveryJournalError.insecureJournalFile
    }
}

private func readJournal(at path: String) throws -> Data? {
    let descriptor = path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else {
        if errno == ENOENT { return nil }
        throw RecoveryJournalError.insecureJournalFile
    }
    defer { _ = close(descriptor) }

    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0 else {
        throw RecoveryJournalError.ioFailure
    }
    try validateJournalMetadata(metadata)

    var data = Data()
    data.reserveCapacity(Int(metadata.st_size))
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = buffer.withUnsafeMutableBytes { bytes in
            Darwin.read(descriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw RecoveryJournalError.ioFailure
        }
        if count == 0 { break }
        guard data.count <= JournalLimits.maximumJournalBytes - count else {
            throw RecoveryJournalError.limitExceeded
        }
        data.append(buffer, count: count)
    }
    guard data.count == Int(metadata.st_size) else {
        throw RecoveryJournalError.insecureJournalFile
    }
    return data
}

private func publishNew(_ data: Data, at location: JournalLocation) throws {
    let temporary = try writeTemporary(data, at: location)
    defer { temporary.withCString { _ = unlink($0) } }

    let result = temporary.withCString { source in
        location.file.withCString { destination in link(source, destination) }
    }
    guard result == 0 else {
        if errno == EEXIST { throw RecoveryJournalError.journalAlreadyExists }
        throw RecoveryJournalError.ioFailure
    }
    temporary.withCString { _ = unlink($0) }
    try synchronizeDirectory(location.directory)
}

private func replaceExisting(_ data: Data, at location: JournalLocation) throws {
    guard try verifyJournalIfPresent(location.file) else {
        throw RecoveryJournalError.journalMissing
    }
    let temporary = try writeTemporary(data, at: location)
    defer { temporary.withCString { _ = unlink($0) } }

    let result = temporary.withCString { source in
        location.file.withCString { destination in rename(source, destination) }
    }
    guard result == 0 else { throw RecoveryJournalError.ioFailure }
    try synchronizeDirectory(location.directory)
}

private func writeTemporary(_ data: Data, at location: JournalLocation) throws -> String {
    var temporary = ""
    var descriptor: Int32 = -1
    for _ in 0..<8 {
        temporary = location.directory + "/." + location.name + "." + UUID().uuidString + ".tmp"
        descriptor = temporary.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        if descriptor >= 0 { break }
        guard errno == EEXIST else { throw RecoveryJournalError.ioFailure }
    }
    guard descriptor >= 0 else { throw RecoveryJournalError.ioFailure }

    var isOpen = true
    var removeOnExit = true
    defer {
        if isOpen { _ = close(descriptor) }
        if removeOnExit {
            temporary.withCString { _ = unlink($0) }
        }
    }
    guard fchmod(descriptor, mode_t(0o600)) == 0 else {
        throw RecoveryJournalError.ioFailure
    }
    try writeAll(data, to: descriptor)
    guard fsync(descriptor) == 0 else { throw RecoveryJournalError.ioFailure }
    guard close(descriptor) == 0 else { throw RecoveryJournalError.ioFailure }
    isOpen = false
    removeOnExit = false
    return temporary
}

private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                throw RecoveryJournalError.ioFailure
            }
            guard count > 0 else { throw RecoveryJournalError.ioFailure }
            offset += count
        }
    }
}

private func synchronizeDirectory(_ path: String) throws {
    let descriptor = path.withCString {
        open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw RecoveryJournalError.ioFailure }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw RecoveryJournalError.ioFailure }
}
