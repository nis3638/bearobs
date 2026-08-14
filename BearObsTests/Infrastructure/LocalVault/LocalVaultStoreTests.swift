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
}
