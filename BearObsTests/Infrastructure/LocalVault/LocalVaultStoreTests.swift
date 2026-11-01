import Darwin
import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsLocalVault
#else
    @testable import BearObs
#endif

final class LocalVaultStoreTests: XCTestCase {
    func testInitializationRejectsEveryInvalidRootShape() throws {
        let remoteURL = try XCTUnwrap(URL(string: "https://example.invalid/vault"))
        XCTAssertThrowsError(try LocalVaultStore(root: remoteURL)) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .invalidRoot)
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try LocalVaultStore(root: missing)) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .unavailableRoot)
        }

        let directory = try makeDirectory()
        let regularFile = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: regularFile)
        XCTAssertThrowsError(try LocalVaultStore(root: regularFile)) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .rootIsNotDirectory)
        }

        let symbolicLink = directory.appendingPathComponent("directory-link")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: directory
        )
        XCTAssertThrowsError(try LocalVaultStore(root: symbolicLink)) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .rootIsSymbolicLink)
        }
    }

    func testListsMetadataAndReadsAStableSnapshotWithoutFollowingLinks() throws {
        let root = try makeDirectory()
        let note = root.appendingPathComponent("Folder/note.md")
        try write(Data("hello".utf8), to: note)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked.md"),
            withDestinationURL: note
        )
        let store = try LocalVaultStore(root: root)

        let metadata = try store.markdownFiles()
        let file = try XCTUnwrap(metadata.first)
        let snapshot = try store.read(file.path, maximumRetainedBytes: 32)

        XCTAssertEqual(metadata.map(\.path.description), ["Folder/note.md"])
        XCTAssertEqual(file.byteSize, 5)
        XCTAssertEqual(snapshot.metadata, file)
        XCTAssertEqual(snapshot.data, Data("hello".utf8))
        XCTAssertEqual(
            snapshot.contentHash.hex,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testHashesButDoesNotRetainContentBeyondTheCallerLimit() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "large.md")
        try write(Data("12345".utf8), to: root.appendingPathComponent("large.md"))
        let store = try LocalVaultStore(root: root)

        let snapshot = try store.read(path, maximumRetainedBytes: 4)

        XCTAssertNil(snapshot.data)
        XCTAssertEqual(snapshot.metadata.byteSize, 5)
        XCTAssertEqual(
            snapshot.contentHash.hex,
            "5994471abb01112afcc18159f6cc74b4f511b99806da59b3caf5a9c173cacfc5"
        )
    }

    func testInventoryContinuesPastAnUnreadableMarkdownFile() throws {
        let root = try makeDirectory()
        let unavailable = root.appendingPathComponent("a-unavailable.md")
        try write(Data("unavailable".utf8), to: unavailable)
        try write(Data("readable".utf8), to: root.appendingPathComponent("b-readable.md"))
        XCTAssertEqual(chmod(unavailable.path, 0), 0)
        defer { _ = chmod(unavailable.path, S_IRUSR | S_IWUSR) }
        let store = try LocalVaultStore(root: root)

        let inventory = try store.markdownInventory()

        XCTAssertEqual(inventory.readable.map(\.path.description), ["b-readable.md"])
        XCTAssertEqual(
            inventory.temporarilyUnavailablePaths.map(\.description),
            ["a-unavailable.md"]
        )
    }

    func testRejectsNegativeRetentionLimit() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        try write(Data(), to: root.appendingPathComponent("note.md"))
        let store = try LocalVaultStore(root: root)

        XCTAssertThrowsError(try store.read(path, maximumRetainedBytes: -1)) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .invalidReadLimit)
        }
    }

    func testRejectsMissingNestedParentForReadsAndReplacements() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "Missing/note.md")
        let store = try LocalVaultStore(root: root)
        let impossibleHash = try ContentHash(hex: String(repeating: "0", count: 64))

        XCTAssertThrowsError(try store.read(path, maximumRetainedBytes: 32)) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .unavailableFile)
        }
        XCTAssertThrowsError(
            try store.replace(
                path,
                with: Data("replacement".utf8),
                expectedContentHash: impossibleHash
            )
        ) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .unavailableFile)
        }
    }

    func testReadRejectsDirectoryMasqueradingAsMarkdownFile() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path.description),
            withIntermediateDirectories: false
        )
        let store = try LocalVaultStore(root: root)

        XCTAssertThrowsError(try store.read(path, maximumRetainedBytes: 32)) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .fileIsNotRegular)
        }
    }

    func testRejectsAReplacementDirectoryAtTheSameRootPath() throws {
        let root = try makeDirectory()
        let store = try LocalVaultStore(root: root)
        let original = root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: original) }
        try FileManager.default.moveItem(at: root, to: original)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        XCTAssertThrowsError(try store.markdownFiles()) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .rootChanged)
        }
    }

    func testReplacesExistingFileOnlyWhenExpectedContentHashMatches() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "Folder/note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("# Before\n\nOriginal body.\n".utf8)
        let replacement = Data("# After\n\nEdited body.\n".utf8)
        try write(original, to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: url.path
        )
        try setExtendedAttribute("preserve-me", named: "com.bearobs.test", at: url)
        let store = try LocalVaultStore(root: root)
        let baseline = try store.read(path, maximumRetainedBytes: original.count)

        let replacementSnapshot = try store.replace(
            path,
            with: replacement,
            expectedContentHash: baseline.contentHash
        )

        let saved = try store.read(path, maximumRetainedBytes: replacement.count)
        XCTAssertEqual(saved.data, replacement)
        XCTAssertEqual(replacementSnapshot.metadata, saved.metadata)
        XCTAssertEqual(replacementSnapshot.contentHash, saved.contentHash)
        XCTAssertEqual(replacementSnapshot.data, saved.data)
        XCTAssertNotEqual(saved.contentHash, baseline.contentHash)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o640))
        XCTAssertEqual(
            try extendedAttribute(named: "com.bearobs.test", at: url),
            "preserve-me"
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("Folder").path
            )
            .contains { $0.hasPrefix(".bearobs-staging-") }
        )
    }

    func testRejectsStaleExpectedContentHashWithoutOverwritingExternalEdit() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("original".utf8)
        let externalEdit = Data("external edit wins".utf8)
        try write(original, to: url)
        let store = try LocalVaultStore(root: root)
        let baseline = try store.read(path, maximumRetainedBytes: original.count)
        try write(externalEdit, to: url)

        XCTAssertThrowsError(
            try store.replace(
                path,
                with: Data("stale editor draft".utf8),
                expectedContentHash: baseline.contentHash
            )
        ) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .contentChanged)
        }
        XCTAssertEqual(try Data(contentsOf: url), externalEdit)
    }

    func testReplacementRefusesSymlinkSwapWithoutWritingOutsideVault() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let note = root.appendingPathComponent(path.description)
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try write(Data("inside".utf8), to: note)
        try write(Data("outside".utf8), to: outside)
        let store = try LocalVaultStore(root: root)
        let baseline = try store.read(path, maximumRetainedBytes: 32)
        try FileManager.default.removeItem(at: note)
        try FileManager.default.createSymbolicLink(at: note, withDestinationURL: outside)

        XCTAssertThrowsError(
            try store.replace(
                path,
                with: Data("escaped write".utf8),
                expectedContentHash: baseline.contentHash
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testPreCommitPOSIXFailuresPreserveOriginalAndRemoveStagingFile() throws {
        let faults: [FaultingAtomicWriteOperations.Fault] = [
            .createStaging,
            .partialWriteThenDiskFull,
            .copyMetadata,
            .setOwner,
            .setPermissions,
            .synchronizeFile,
            .closeFile,
            .replace,
        ]
        let original = Data("original bytes".utf8)
        let replacement = Data(repeating: 0x41, count: 128 * 1_024)

        for fault in faults {
            let root = try makeDirectory()
            let path = try VaultPath(decodedRelativePath: "Folder/note.md")
            let url = root.appendingPathComponent(path.description)
            try write(original, to: url)
            let baseline = try LocalVaultStore(root: root).read(
                path,
                maximumRetainedBytes: original.count
            )
            let store = try LocalVaultStore(
                root: root,
                atomicWriteOperations: FaultingAtomicWriteOperations(fault: fault)
            )

            XCTAssertThrowsError(
                try store.replace(
                    path,
                    with: replacement,
                    expectedContentHash: baseline.contentHash
                ),
                "Expected failure for \(fault)"
            ) {
                XCTAssertEqual(
                    $0 as? LocalVaultStoreError,
                    .atomicWriteFailed(.notCommitted)
                )
            }
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertFalse(
                try containsStagingFile(in: url.deletingLastPathComponent()),
                "Unexpected staging residue after \(fault)"
            )
        }
    }

    func testInterruptedWriteRetriesAndCommitsCompleteReplacement() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("original".utf8)
        let replacement = Data(repeating: 0x42, count: 128 * 1_024)
        try write(original, to: url)
        let baseline = try LocalVaultStore(root: root).read(
            path,
            maximumRetainedBytes: original.count
        )
        let store = try LocalVaultStore(
            root: root,
            atomicWriteOperations: FaultingAtomicWriteOperations(fault: .interruptedWrite)
        )

        let saved = try store.replace(
            path,
            with: replacement,
            expectedContentHash: baseline.contentHash
        )

        XCTAssertEqual(saved.data, replacement)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertFalse(try containsStagingFile(in: root))
    }

    func testDirectorySyncFailureReportsCommittedButDurabilityUncertain() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        try write(original, to: url)
        let baseline = try LocalVaultStore(root: root).read(
            path,
            maximumRetainedBytes: original.count
        )
        let store = try LocalVaultStore(
            root: root,
            atomicWriteOperations: FaultingAtomicWriteOperations(
                fault: .synchronizeDirectory
            )
        )

        XCTAssertThrowsError(
            try store.replace(
                path,
                with: replacement,
                expectedContentHash: baseline.contentHash
            )
        ) {
            XCTAssertEqual(
                $0 as? LocalVaultStoreError,
                .atomicWriteFailed(.committedButDurabilityUncertain)
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertFalse(try containsStagingFile(in: root))
    }

    func testPostCommitVerificationFailureReportsDurableButUnverified() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("original".utf8)
        let replacement = Data("replacement".utf8)
        try write(original, to: url)
        let baseline = try LocalVaultStore(root: root).read(
            path,
            maximumRetainedBytes: original.count
        )
        let store = try LocalVaultStore(
            root: root,
            atomicWriteOperations: POSIXLocalVaultAtomicWriteOperations(),
            atomicWriteCheckpoint: { checkpoint in
                if checkpoint == .verifyCommittedFile { throw InjectedWriteFault() }
            }
        )

        XCTAssertThrowsError(
            try store.replace(
                path,
                with: replacement,
                expectedContentHash: baseline.contentHash
            )
        ) {
            XCTAssertEqual(
                $0 as? LocalVaultStoreError,
                .atomicWriteFailed(.committedAndDurableButVerificationFailed)
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertFalse(try containsStagingFile(in: root))
    }

    func testDestinationChangeBeforeValidationIsNotSilentlyOverwritten() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("original".utf8)
        let external = Data("external edit".utf8)
        try write(original, to: url)
        let baseline = try LocalVaultStore(root: root).read(
            path,
            maximumRetainedBytes: original.count
        )
        let store = try LocalVaultStore(
            root: root,
            atomicWriteOperations: POSIXLocalVaultAtomicWriteOperations(),
            atomicWriteCheckpoint: { checkpoint in
                if checkpoint == .validateDestination {
                    try external.write(to: url)
                }
            }
        )

        XCTAssertThrowsError(
            try store.replace(
                path,
                with: Data("replacement".utf8),
                expectedContentHash: baseline.contentHash
            )
        ) {
            XCTAssertEqual($0 as? LocalVaultStoreError, .contentChanged)
        }
        XCTAssertEqual(try Data(contentsOf: url), external)
        XCTAssertFalse(try containsStagingFile(in: root))
    }

    func testForeignReplacementOfStagingIsNotDeletedOrPublished() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("original".utf8)
        let foreign = Data("foreign".utf8)
        try write(original, to: url)
        let baseline = try LocalVaultStore(root: root).read(
            path,
            maximumRetainedBytes: original.count
        )
        let store = try LocalVaultStore(
            root: root,
            atomicWriteOperations: POSIXLocalVaultAtomicWriteOperations(),
            atomicWriteCheckpoint: { checkpoint in
                guard checkpoint == .validateStagingFile else { return }
                let stagingName = try FileManager.default.contentsOfDirectory(
                    atPath: root.path
                ).first { $0.hasPrefix(".bearobs-staging-") }
                let staging = root.appendingPathComponent(try XCTUnwrap(stagingName))
                try FileManager.default.removeItem(at: staging)
                try foreign.write(to: staging)
            }
        )

        XCTAssertThrowsError(
            try store.replace(
                path,
                with: Data("replacement".utf8),
                expectedContentHash: baseline.contentHash
            )
        ) {
            XCTAssertEqual(
                $0 as? LocalVaultStoreError,
                .atomicWriteFailed(.notCommitted)
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        let staging = try XCTUnwrap(try stagingFile(in: root))
        XCTAssertEqual(try Data(contentsOf: staging), foreign)
    }

    func testCleanupFailureKeepsPrimaryFailureAndOriginalTarget() throws {
        let root = try makeDirectory()
        let path = try VaultPath(decodedRelativePath: "note.md")
        let url = root.appendingPathComponent(path.description)
        let original = Data("original".utf8)
        try write(original, to: url)
        let baseline = try LocalVaultStore(root: root).read(
            path,
            maximumRetainedBytes: original.count
        )
        let store = try LocalVaultStore(
            root: root,
            atomicWriteOperations: FaultingAtomicWriteOperations(
                fault: .partialWriteThenDiskFull,
                cleanupAlsoFails: true
            )
        )

        XCTAssertThrowsError(
            try store.replace(
                path,
                with: Data(repeating: 0x43, count: 128 * 1_024),
                expectedContentHash: baseline.contentHash
            )
        ) {
            XCTAssertEqual(
                $0 as? LocalVaultStoreError,
                .atomicWriteFailed(.notCommitted)
            )
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertTrue(try containsStagingFile(in: root))
    }
}

extension LocalVaultStoreTests {
    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private func setExtendedAttribute(_ value: String, named name: String, at url: URL) throws {
        let result = value.utf8CString.withUnsafeBytes { valueBytes in
            name.withCString { namePointer in
                setxattr(
                    url.path,
                    namePointer,
                    valueBytes.baseAddress,
                    valueBytes.count - 1,
                    0,
                    0
                )
            }
        }
        guard result == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func extendedAttribute(named name: String, at url: URL) throws -> String {
        let size = name.withCString { getxattr(url.path, $0, nil, 0, 0, 0) }
        guard size >= 0 else { throw CocoaError(.fileReadUnknown) }
        var bytes = [UInt8](repeating: 0, count: size)
        let count = name.withCString { namePointer in
            getxattr(url.path, namePointer, &bytes, bytes.count, 0, 0)
        }
        guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
        return try XCTUnwrap(String(bytes: bytes.prefix(count), encoding: .utf8))
    }

    private func containsStagingFile(in directory: URL) throws -> Bool {
        try stagingFile(in: directory) != nil
    }

    private func stagingFile(in directory: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .first { $0.hasPrefix(".bearobs-staging-") }
            .map { directory.appendingPathComponent($0) }
    }
}

private struct InjectedWriteFault: Error {}

private final class FaultingAtomicWriteOperations: LocalVaultAtomicWriteOperations,
    @unchecked Sendable
{
    enum Fault: Equatable {
        case createStaging
        case interruptedWrite
        case partialWriteThenDiskFull
        case copyMetadata
        case setOwner
        case setPermissions
        case synchronizeFile
        case closeFile
        case replace
        case synchronizeDirectory
    }

    private let base = POSIXLocalVaultAtomicWriteOperations()
    private let fault: Fault
    private let cleanupAlsoFails: Bool
    private var fired = false

    init(fault: Fault, cleanupAlsoFails: Bool = false) {
        self.fault = fault
        self.cleanupAlsoFails = cleanupAlsoFails
    }

    func createStaging(named name: String, in directory: Int32) -> Int32 {
        guard fault != .createStaging else { return fail(ENOSPC) }
        return base.createStaging(named: name, in: directory)
    }

    func write(
        _ data: Data,
        offset: Int,
        maximumCount: Int,
        to descriptor: Int32
    ) -> Int {
        if fault == .interruptedWrite, !fired {
            fired = true
            return Int(fail(EINTR))
        }
        if fault == .partialWriteThenDiskFull {
            guard !fired else { return Int(fail(ENOSPC)) }
            fired = true
            return base.write(
                data,
                offset: offset,
                maximumCount: min(32, maximumCount),
                to: descriptor
            )
        }
        return base.write(
            data,
            offset: offset,
            maximumCount: maximumCount,
            to: descriptor
        )
    }

    func copyMetadata(from source: Int32, to destination: Int32) -> Int32 {
        guard fault != .copyMetadata else { return fail(EACCES) }
        return base.copyMetadata(from: source, to: destination)
    }

    func setOwner(_ owner: uid_t, group: gid_t, of descriptor: Int32) -> Int32 {
        guard fault != .setOwner else { return fail(EPERM) }
        return base.setOwner(owner, group: group, of: descriptor)
    }

    func setPermissions(_ permissions: mode_t, of descriptor: Int32) -> Int32 {
        guard fault != .setPermissions else { return fail(EACCES) }
        return base.setPermissions(permissions, of: descriptor)
    }

    func synchronizeFile(_ descriptor: Int32) -> Int32 {
        guard fault != .synchronizeFile else { return fail(EIO) }
        return base.synchronizeFile(descriptor)
    }

    func closeFile(_ descriptor: Int32) -> Int32 {
        guard fault == .closeFile, !fired else { return base.closeFile(descriptor) }
        fired = true
        _ = base.closeFile(descriptor)
        return fail(EIO)
    }

    func replace(
        stagingName: String,
        destinationName: String,
        in directory: Int32
    ) -> Int32 {
        guard fault != .replace else { return fail(EIO) }
        return base.replace(
            stagingName: stagingName,
            destinationName: destinationName,
            in: directory
        )
    }

    func synchronizeDirectory(_ descriptor: Int32) -> Int32 {
        guard fault != .synchronizeDirectory else { return fail(EIO) }
        return base.synchronizeDirectory(descriptor)
    }

    func remove(named name: String, from directory: Int32) -> Int32 {
        guard !cleanupAlsoFails else { return fail(EACCES) }
        return base.remove(named: name, from: directory)
    }

    private func fail(_ code: Int32) -> Int32 {
        errno = code
        return -1
    }
}
