import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsUserState
#else
    @testable import BearObs
#endif

final class VaultSelectionStoreTests: XCTestCase {
    func testSecurityScopedBookmarkResolvesTheSelectedDirectory() throws {
        let directory = try makeDirectory()
        let selection = try VaultSelection.make(for: directory)

        let resolved = try selection.resolve()

        XCTAssertEqual(
            resolved.url.standardizedFileURL,
            directory.standardizedFileURL
        )
    }

    func testMissingSelectionIsEmpty() throws {
        let directory = try makeDirectory()
        let store = try VaultSelectionStore(directory: directory)

        XCTAssertNil(try store.load())
    }

    func testSelectionRoundTripsWithoutExposingThePath() throws {
        let directory = try makeDirectory()
        let store = try VaultSelectionStore(directory: directory)
        let selection = VaultSelection(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            bookmarkData: Data([0, 1, 2, 255])
        )

        try store.save(selection)

        XCTAssertEqual(try store.load(), selection)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("selected-vault.json").path
            )
        )
    }

    func testRejectsASelectionFileSymlink() throws {
        let directory = try makeDirectory()
        let target = directory.appendingPathComponent("outside.json")
        let selectionFile = directory.appendingPathComponent("selected-vault.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: selectionFile,
            withDestinationURL: target
        )
        let store = try VaultSelectionStore(directory: directory)

        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? VaultSelectionStoreError, .selectionFileIsSymbolicLink)
        }
    }
}

extension VaultSelectionStoreTests {
    fileprivate func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
