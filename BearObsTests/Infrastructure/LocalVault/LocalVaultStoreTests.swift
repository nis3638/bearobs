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
}
