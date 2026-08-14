import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsIndex
    import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class IndexTagRepositoryTests: XCTestCase {
    func testListsTagsWithStableDisplayNameAndNoteCount() async throws {
        let repository = try makeRepository()
        try await insert("---\ntags: [Swift, 中文]\n---\nfirst", at: "a.md", in: repository)
        try await insert("---\ntags: [swift]\n---\nsecond", at: "b.md", in: repository)

        let tags = try await repository.libraryTags()

        XCTAssertEqual(tags.map(\.normalizedName), ["swift", "中文"])
        XCTAssertEqual(tags.map(\.displayName), ["Swift", "中文"])
        XCTAssertEqual(tags.map(\.noteCount), [2, 1])
    }

    func testReturnsOnlyNotesForSelectedTagInLibraryOrder() async throws {
        let repository = try makeRepository()
        try await insert(
            "---\ntags: [project/mobile]\n---\nolder",
            at: "old.md",
            modifiedAt: 1,
            in: repository
        )
        try await insert(
            "---\ntags: [project/mobile]\n---\nnewer",
            at: "new.md",
            modifiedAt: 2,
            in: repository
        )
        try await insert("---\ntags: [other]\n---\nother", at: "other.md", in: repository)
        let tags = try await repository.libraryTags()
        let tag = try XCTUnwrap(tags.first { $0.normalizedName == "project/mobile" })

        let notes = try await repository.libraryNotes(taggedWith: tag)

        XCTAssertEqual(notes.map(\.path.description), ["new.md", "old.md"])
    }
}

extension IndexTagRepositoryTests {
    private func makeRepository() throws -> SQLiteIndexRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
    }

    private func insert(
        _ source: String,
        at rawPath: String,
        modifiedAt: TimeInterval = 0,
        in repository: SQLiteIndexRepository
    ) async throws {
        let path = try VaultPath(decodedRelativePath: rawPath)
        let data = Data(source.utf8)
        let parsed = try MarkdownNoteParser.parse(data, at: path)
        try await repository.replace(
            try IndexNoteInput(
                path: path,
                parsedNote: parsed,
                contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
                modifiedAt: Date(timeIntervalSince1970: modifiedAt),
                byteSize: Int64(data.count)
            )
        )
    }
}
