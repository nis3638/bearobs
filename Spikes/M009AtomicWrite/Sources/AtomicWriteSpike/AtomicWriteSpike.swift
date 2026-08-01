import Foundation

public enum AtomicWriteCommitState: Equatable, Sendable {
    case notCommitted
    case committedButDurabilityUncertain
    case committedAndDurableButVerificationFailed
}

public enum AtomicWriteOperation: String, Equatable, Sendable {
    case validateDestination
    case openDirectory
    case inspectDestination
    case createStaging
    case writeStaging
    case setPermissions
    case synchronizeStaging
    case closeStaging
    case replaceDestination
    case synchronizeDirectory
    case verifyDestination
    case checkpoint
}

public struct AtomicWriteFailure: Error, Equatable, Sendable {
    public let operation: AtomicWriteOperation
    public let code: Int32
    public let commitState: AtomicWriteCommitState

    public init(
        operation: AtomicWriteOperation,
        code: Int32,
        commitState: AtomicWriteCommitState
    ) {
        self.operation = operation
        self.code = code
        self.commitState = commitState
    }
}

public struct AtomicWriteReceipt: Equatable, Sendable {
    public let byteCount: Int

    public init(byteCount: Int) {
        self.byteCount = byteCount
    }
}

package enum AtomicWriteStage: String, CaseIterable, Sendable {
    case stagingCreated
    case partialDataWritten
    case dataWritten
    case fileSynchronized
    case stagingClosed
    case destinationReplaced
    case directorySynchronized
}

struct AtomicPOSIXError: Error {
    let code: Int32
}

struct AtomicFileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

struct AtomicExistingFile {
    let permissions: UInt16
    let identity: AtomicFileIdentity
}

struct AtomicStagingFile {
    let descriptor: Int32
    let identity: AtomicFileIdentity
}

protocol AtomicFileOperations: AnyObject {
    func openDirectory(at path: String) throws -> Int32
    func existingRegularFile(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> AtomicExistingFile
    func openExclusiveStaging(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> AtomicStagingFile
    func writeAll(_ data: Data, to descriptor: Int32) throws
    func setPermissions(_ permissions: UInt16, of descriptor: Int32) throws
    func synchronizeFile(_ descriptor: Int32) throws
    func closeFile(_ descriptor: Int32) throws
    func publish(
        stagingName: String,
        stagingIdentity: AtomicFileIdentity,
        destinationName: String,
        destinationIdentity: AtomicFileIdentity,
        in directoryDescriptor: Int32
    ) throws
    func synchronizeDirectory(_ descriptor: Int32) throws
    func readFile(
        named name: String,
        expectedIdentity: AtomicFileIdentity,
        expectedByteCount: Int,
        in directoryDescriptor: Int32
    ) throws -> Data
    func removeOwnedStaging(
        named name: String,
        identity: AtomicFileIdentity,
        in directoryDescriptor: Int32
    ) throws
}
