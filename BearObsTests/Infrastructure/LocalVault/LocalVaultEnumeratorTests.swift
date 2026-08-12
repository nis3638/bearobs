import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsLocalVault
#else
    @testable import BearObs
#endif

final class LocalVaultEnumeratorTests: XCTestCase {
    func testEnumeratesMarkdownRecursivelyInDeterministicOrder() throws {
        let root = try makeDirectory(named: "vault")
        try write("root", to: root.appendingPathComponent("a.md"))
        try write("ignored", to: root.appendingPathComponent("asset.svg"))
        try write("upper", to: root.appendingPathComponent("b.MD"))
        try write(
            "unicode",
            to: root.appendingPathComponent("Unicode/空 格%计划.md")
        )

        let paths = try collectPaths(from: root)

        XCTAssertEqual(
            paths.map(\.description),
            ["Unicode/空 格%计划.md", "a.md", "b.MD"]
        )
    }

    func testExcludesReservedDirectoriesAndNonMarkdownFiles() throws {
        let root = try makeDirectory(named: "vault")
        try write("visible", to: root.appendingPathComponent("visible.md"))
        try write("private", to: root.appendingPathComponent(".obsidian/private.md"))
        try write("deleted", to: root.appendingPathComponent(".trash/deleted.md"))
        try write("internal", to: root.appendingPathComponent(".bearobs/internal.md"))
        try write("not markdown", to: root.appendingPathComponent("README.markdown"))

        XCTAssertEqual(
            try collectPaths(from: root).map(\.description),
            ["visible.md"]
        )
    }

    func testSkipsFileAndDirectorySymbolicLinks() throws {
        let root = try makeDirectory(named: "vault")
        let outside = try makeDirectory(named: "outside")
        let outsideNote = outside.appendingPathComponent("outside.md")
        try write("outside", to: outsideNote)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-directory"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-file.md"),
            withDestinationURL: outsideNote
        )
        try write("inside", to: root.appendingPathComponent("inside.md"))

        XCTAssertEqual(
            try collectPaths(from: root).map(\.description),
            ["inside.md"]
        )
    }

    func testRejectsInvalidMissingFileAndSymbolicLinkRoots() throws {
        let parent = try makeDirectory(named: "roots")
        let file = parent.appendingPathComponent("note.md")
        let directory = parent.appendingPathComponent("directory", isDirectory: true)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try write("note", to: file)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: directory
        )

        assertEnumerationError(.invalidRoot, at: URL(string: "https://example.invalid")!)
        assertEnumerationError(
            .unavailableRoot,
            at: parent.appendingPathComponent("missing")
        )
        assertEnumerationError(.rootIsNotDirectory, at: file)
        assertEnumerationError(.rootIsSymbolicLink, at: link)
    }

    func testVisitorFailureStopsEnumeration() throws {
        enum Stop: Error { case now }
        let root = try makeDirectory(named: "vault")
        try write("first", to: root.appendingPathComponent("a.md"))
        try write("second", to: root.appendingPathComponent("b.md"))
        var visited: [VaultPath] = []

        XCTAssertThrowsError(
            try LocalVaultEnumerator().enumerateMarkdown(at: root) { path in
                visited.append(path)
                throw Stop.now
            }
        ) { error in
            XCTAssertTrue(error is Stop)
        }
        XCTAssertEqual(visited.map(\.description), ["a.md"])
    }

    func testGoldenVaultEnumerationPreservesPathContract() throws {
        #if SWIFT_PACKAGE
            let bundle = Bundle.module
        #else
            let bundle = Bundle(for: Self.self)
        #endif
        let fixture = try XCTUnwrap(
            bundle.url(forResource: "GoldenVault", withExtension: nil)
        )
        let root = fixture.appendingPathComponent("vault", isDirectory: true)
        let paths = try collectPaths(from: root)

        XCTAssertEqual(paths.count, 272)
        XCTAssertTrue(paths.contains { $0.description == "Links/Unicode/空 格%计划.md" })
        XCTAssertFalse(paths.contains { $0.description == "Assets/local.svg" })
    }
}

extension LocalVaultEnumeratorTests {
    fileprivate func assertEnumerationError(
        _ expected: LocalVaultEnumerationError,
        at root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try collectPaths(from: root),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? LocalVaultEnumerationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    fileprivate func collectPaths(from root: URL) throws -> [VaultPath] {
        var paths: [VaultPath] = []
        try LocalVaultEnumerator().enumerateMarkdown(at: root) { paths.append($0) }
        return paths
    }

    fileprivate func makeDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(
                at: root.deletingLastPathComponent()
            )
        }
        return root
    }

    fileprivate func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(content.utf8).write(to: url)
    }
}
