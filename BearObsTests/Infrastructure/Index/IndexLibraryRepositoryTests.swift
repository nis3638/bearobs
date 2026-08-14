import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsIndex
    import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class IndexLibraryRepositoryTests: XCTestCase {
    func testLibraryNotesAreNewestFirstWithStablePathTieBreak() async throws {
        let repository = try makeRepository()
        try await insert("# Alpha\n\nFirst preview.", at: "a.md", modifiedAt: 20, in: repository)
        try await insert("# Beta\n\nSecond preview.", at: "b.md", modifiedAt: 20, in: repository)
        try await insert("# Old\n\nOld preview.", at: "old.md", modifiedAt: 10, in: repository)

        let notes = try await repository.libraryNotes()

        XCTAssertEqual(notes.map(\.path.description), ["a.md", "b.md", "old.md"])
        XCTAssertEqual(notes.map(\.title), ["Alpha", "Beta", "Old"])
        XCTAssertEqual(notes.first?.preview, "First preview.")
        XCTAssertEqual(notes.map(\.parseStatus), [.complete, .complete, .complete])
    }

    func testLibraryNotesExposeDegradedAndFailedStateWithoutDiagnostics() async throws {
        let repository = try makeRepository()
        try await insert(
            "---\ntitle: [\n---\nreadable",
            at: "degraded.md",
            modifiedAt: 2,
            in: repository
        )
        let failedPath = try VaultPath(decodedRelativePath: "failed.md")
        try await repository.replaceFailure(
            at: failedPath,
            contentHash: try ContentHash(hex: String(repeating: "f", count: 64)),
            modifiedAt: Date(timeIntervalSince1970: 1),
            byteSize: 1,
            diagnostic: "markdown.invalid-utf8"
        )

        let notes = try await repository.libraryNotes()

        XCTAssertEqual(notes.map(\.parseStatus), [.degraded, .failed])
        XCTAssertEqual(
            notes.map(\.path),
            [
                try VaultPath(decodedRelativePath: "degraded.md"),
                failedPath,
            ])
    }
}

extension IndexLibraryRepositoryTests {
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
        modifiedAt: TimeInterval,
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
