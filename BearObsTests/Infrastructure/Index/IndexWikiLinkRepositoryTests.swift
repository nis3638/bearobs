import Foundation
import GRDB
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    @testable import BearObsIndex
    import BearObsMarkdown
#else
    @testable import BearObs
#endif

final class IndexWikiLinkRepositoryTests: XCTestCase {
    func testResolutionUsesDocumentedPriorityAndNeverGuessesAmbiguousTargets() throws {
        let paths = try [
            "Area/Source.md",
            "Area/Target.md",
            "Target.md",
            "Folder/Explicit.md",
            "Area/Folder/Explicit.md",
            "Deep/Unique.md",
            "One/Twin.md",
            "Two/Twin.md",
        ].map(VaultPath.init(decodedRelativePath:))
        let catalog = WikiLinkCatalog(paths: paths)
        let source = paths[0]

        XCTAssertEqual(catalog.resolve("Folder/Explicit", from: source), .resolved(paths[3]))
        XCTAssertEqual(catalog.resolve("Target", from: source), .resolved(paths[1]))
        XCTAssertEqual(catalog.resolve("Unique#Section", from: source), .resolved(paths[5]))
        XCTAssertEqual(catalog.resolve("Twin", from: source), .ambiguous)
        XCTAssertEqual(catalog.resolve("Missing", from: source), .missing)
    }

    func testResolutionRejectsTraversalAbsoluteSeparatorsAndEmptyHeadingTargets() throws {
        let source = try VaultPath(decodedRelativePath: "Area/Source.md")
        let catalog = WikiLinkCatalog(paths: [source])

        for target in ["../Secret", "/Secret", "Area\\Secret", "#Heading", "   "] {
            XCTAssertEqual(catalog.resolve(target, from: source), .missing, target)
        }
    }

    func testRepositoryPersistsResolutionAndRecomputesAfterCandidateRemoval() async throws {
        let fixture = try makeFixture()
        try await insert(
            "[[Twin]] [[Folder/Exact|Alias]] [[Missing]]", at: "Source.md", in: fixture)
        try await insert("# One", at: "One/Twin.md", in: fixture)
        try await insert("# Two", at: "Two/Twin.md", in: fixture)
        try await insert("# Exact", at: "Folder/Exact.md", in: fixture)

        try await fixture.resolveAllWikiLinks()
        let initial = try await fixture.wikiLinks(in: path("Source.md"))

        XCTAssertEqual(
            initial.map(\.resolution),
            [
                .ambiguous,
                .resolved(path("Folder/Exact.md")),
                .missing,
            ])
        let persisted = try await fixture.databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT resolution_state, resolved_path FROM links ORDER BY source_start"
            ).map { row in
                (row["resolution_state"] as String, row["resolved_path"] as String?)
            }
        }
        XCTAssertEqual(persisted.map(\.0), ["ambiguous", "resolved", "missing"])
        XCTAssertNil(persisted[0].1)
        XCTAssertEqual(persisted[1].1, "Folder/Exact.md")

        try await fixture.remove(path("Two/Twin.md"))
        try await fixture.resolveAllWikiLinks()
        let updated = try await fixture.wikiLinks(in: path("Source.md"))
        XCTAssertEqual(updated[0].resolution, .resolved(path("One/Twin.md")))
    }
}

extension IndexWikiLinkRepositoryTests {
    private func makeFixture() throws -> SQLiteIndexRepository {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path)
    }

    private func insert(
        _ source: String,
        at rawPath: String,
        in repository: SQLiteIndexRepository
    ) async throws {
        let notePath = path(rawPath)
        let data = Data(source.utf8)
        let note = try MarkdownNoteParser.parse(data, at: notePath)
        try await repository.replace(
            IndexNoteInput(
                path: notePath,
                parsedNote: note,
                contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
                modifiedAt: .distantPast,
                byteSize: Int64(data.count)
            )
        )
    }

    private func path(_ value: String) -> VaultPath {
        try! VaultPath(decodedRelativePath: value)
    }
}
