import Darwin
import Foundation

public struct AtomicFileWriter {
    private let operations: any AtomicFileOperations
    private let stagingName: () -> String
    private let checkpoint: (AtomicWriteStage) throws -> Void

    public init() {
        self.init(
            operations: POSIXAtomicFileOperations(),
            stagingName: { ".bearobs-staging-\(UUID().uuidString).tmp" }
        )
    }

    init(
        operations: any AtomicFileOperations,
        stagingName: @escaping () -> String,
        checkpoint: @escaping (AtomicWriteStage) throws -> Void = { _ in }
    ) {
        self.operations = operations
        self.stagingName = stagingName
        self.checkpoint = checkpoint
    }

    package init(
        checkpoint: @escaping (AtomicWriteStage) throws -> Void
    ) {
        self.init(
            operations: POSIXAtomicFileOperations(),
            stagingName: { ".bearobs-staging-\(UUID().uuidString).tmp" },
            checkpoint: checkpoint
        )
    }

    public func replaceExistingFile(
        at destination: URL,
        with bytes: Data
    ) throws -> AtomicWriteReceipt {
        guard destination.isFileURL else {
            throw failure(.validateDestination, EINVAL, .notCommitted)
        }
        let directoryPath = destination.deletingLastPathComponent().path
        let destinationName = destination.lastPathComponent
        let directory = try perform(.openDirectory, .notCommitted) {
            try operations.openDirectory(at: directoryPath)
        }
        defer { try? operations.closeFile(directory) }

        let existing = try perform(.inspectDestination, .notCommitted) {
            try operations.existingRegularFile(
                named: destinationName,
                in: directory
            )
        }
        return try replace(
            destinationName: destinationName,
            existing: existing,
            bytes: bytes,
            directory: directory
        )
    }

    private func replace(
        destinationName: String,
        existing: AtomicExistingFile,
        bytes: Data,
        directory: Int32
    ) throws -> AtomicWriteReceipt {
        let name = stagingName()
        let staging = try prepareStaging(
            named: name,
            permissions: existing.permissions,
            bytes: bytes,
            directory: directory
        )
        var ownsStaging = true
        defer {
            if ownsStaging {
                try? operations.removeOwnedStaging(
                    named: name,
                    identity: staging.identity,
                    in: directory
                )
            }
        }
        try publish(
            name,
            staging,
            over: destinationName,
            existing: existing,
            directory: directory
        )
        ownsStaging = false
        try finish(
            bytes,
            destinationName: destinationName,
            identity: staging.identity,
            directory: directory
        )
        return AtomicWriteReceipt(byteCount: bytes.count)
    }

    private func prepareStaging(
        named name: String,
        permissions: UInt16,
        bytes: Data,
        directory: Int32
    ) throws -> AtomicStagingFile {
        let staging = try perform(.createStaging, .notCommitted) {
            try operations.openExclusiveStaging(named: name, in: directory)
        }
        var descriptorIsOpen = true
        var ownsStaging = true
        defer {
            if descriptorIsOpen { try? operations.closeFile(staging.descriptor) }
            if ownsStaging {
                try? operations.removeOwnedStaging(
                    named: name,
                    identity: staging.identity,
                    in: directory
                )
            }
        }
        try checkpoint(.stagingCreated, state: .notCommitted)
        try write(bytes, to: staging.descriptor)
        try perform(.setPermissions, .notCommitted) {
            try operations.setPermissions(permissions, of: staging.descriptor)
        }
        try perform(.synchronizeStaging, .notCommitted) {
            try operations.synchronizeFile(staging.descriptor)
        }
        try checkpoint(.fileSynchronized, state: .notCommitted)
        descriptorIsOpen = false
        try perform(.closeStaging, .notCommitted) {
            try operations.closeFile(staging.descriptor)
        }
        try checkpoint(.stagingClosed, state: .notCommitted)
        ownsStaging = false
        return staging
    }

    private func write(_ bytes: Data, to descriptor: Int32) throws {
        let midpoint = bytes.count / 2
        if midpoint > 0 {
            try perform(.writeStaging, .notCommitted) {
                try operations.writeAll(Data(bytes.prefix(midpoint)), to: descriptor)
            }
            try checkpoint(.partialDataWritten, state: .notCommitted)
        }
        try perform(.writeStaging, .notCommitted) {
            try operations.writeAll(Data(bytes.dropFirst(midpoint)), to: descriptor)
        }
        try checkpoint(.dataWritten, state: .notCommitted)
    }

    private func publish(
        _ name: String,
        _ staging: AtomicStagingFile,
        over destinationName: String,
        existing: AtomicExistingFile,
        directory: Int32
    ) throws {
        try perform(.replaceDestination, .notCommitted) {
            try operations.publish(
                stagingName: name,
                stagingIdentity: staging.identity,
                destinationName: destinationName,
                destinationIdentity: existing.identity,
                in: directory
            )
        }
        try checkpoint(
            .destinationReplaced,
            state: .committedButDurabilityUncertain
        )
    }

    private func finish(
        _ expected: Data,
        destinationName: String,
        identity: AtomicFileIdentity,
        directory: Int32
    ) throws {
        try perform(.synchronizeDirectory, .committedButDurabilityUncertain) {
            try operations.synchronizeDirectory(directory)
        }
        try checkpoint(
            .directorySynchronized,
            state: .committedAndDurableButVerificationFailed
        )
        let actual = try perform(
            .verifyDestination,
            .committedAndDurableButVerificationFailed
        ) {
            try operations.readFile(
                named: destinationName,
                expectedIdentity: identity,
                expectedByteCount: expected.count,
                in: directory
            )
        }
        guard actual == expected else {
            throw failure(
                .verifyDestination,
                EIO,
                .committedAndDurableButVerificationFailed
            )
        }
    }

    private func checkpoint(
        _ stage: AtomicWriteStage,
        state: AtomicWriteCommitState
    ) throws {
        try perform(.checkpoint, state) {
            try checkpoint(stage)
        }
    }

    private func perform<T>(
        _ operation: AtomicWriteOperation,
        _ state: AtomicWriteCommitState,
        _ body: () throws -> T
    ) throws -> T {
        do {
            return try body()
        } catch let error as AtomicWriteFailure {
            throw error
        } catch let error as AtomicPOSIXError {
            throw failure(operation, error.code, state)
        } catch {
            throw failure(operation, ECANCELED, state)
        }
    }

    private func failure(
        _ operation: AtomicWriteOperation,
        _ code: Int32,
        _ state: AtomicWriteCommitState
    ) -> AtomicWriteFailure {
        AtomicWriteFailure(operation: operation, code: code, commitState: state)
    }
}
