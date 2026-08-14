import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

@MainActor
final class FavoritesFeatureModelTests: XCTestCase {
    func testInitialStateIsLoadingWithNoFavoritePaths() {
        let model = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [] },
                loadFavoritePaths: { [] },
                setFavorite: { _, _ in [] }
            )
        )

        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.favoritePaths, [])
    }

    func testLoadIntersectsFavoritesWithIndexWithoutReorderingOrDroppingStalePaths() async throws {
        let first = makeNote(
            path: try makePath("Projects/B.md"),
            title: "Index first",
            modifiedAt: Date(timeIntervalSince1970: 10)
        )
        let second = makeNote(
            path: try makePath("Projects/A.md"),
            title: "Index second",
            modifiedAt: Date(timeIntervalSince1970: 30)
        )
        let notFavorite = makeNote(path: try makePath("Projects/C.md"), title: "Not favorite")
        let stalePath = try makePath("Archive/Removed.md")
        let favoritePaths: Set<VaultPath> = [first.path, second.path, stalePath]
        let model = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [first, second, notFavorite] },
                loadFavoritePaths: { favoritePaths },
                setFavorite: { _, _ in favoritePaths }
            )
        )

        await model.load()

        XCTAssertEqual(model.state, .content([first, second]))
        XCTAssertEqual(model.favoritePaths, favoritePaths)
        XCTAssertTrue(model.isFavorite(stalePath))
        XCTAssertFalse(model.isFavorite(notFavorite.path))
    }

    func testLoadPublishesEmptyWhenNoFavoritePathExistsInIndex() async throws {
        let note = makeNote(path: try makePath("Visible.md"))
        let stalePath = try makePath("Removed.md")
        let model = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [stalePath] },
                setFavorite: { _, _ in [stalePath] }
            )
        )

        await model.load()

        XCTAssertEqual(model.state, .empty)
        XCTAssertEqual(model.favoritePaths, [stalePath])
        XCTAssertTrue(model.isFavorite(stalePath))
    }

    func testLoadMapsEitherUnderlyingErrorToFixedPublicFailure() async throws {
        let note = makeNote(path: try makePath("Note.md"))
        let notesSecret = "private index path"
        let favoritesSecret = "private user-state contents"
        let notesFailure = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { throw PrivateFailure.sensitive(notesSecret) },
                loadFavoritePaths: { [] },
                setFavorite: { _, _ in [] }
            )
        )
        let favoritesFailure = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { throw PrivateFailure.sensitive(favoritesSecret) },
                setFavorite: { _, _ in [] }
            )
        )

        await notesFailure.load()
        await favoritesFailure.load()

        XCTAssertEqual(notesFailure.state, .failure(.loadFailed, visibleNotes: []))
        XCTAssertEqual(favoritesFailure.state, .failure(.loadFailed, visibleNotes: []))
        XCTAssertFalse(String(reflecting: notesFailure.state).contains(notesSecret))
        XCTAssertFalse(String(reflecting: favoritesFailure.state).contains(favoritesSecret))
    }

    func testSetFavoriteSuccessPublishesFavoriteAndVisibleContent() async throws {
        let note = makeNote(path: try makePath("Pinned.md"))
        let model = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [] },
                setFavorite: { path, isFavorite in
                    isFavorite ? [path] : []
                }
            )
        )
        await model.load()
        XCTAssertEqual(model.state, .empty)

        await model.setFavorite(note.path, isFavorite: true)

        XCTAssertEqual(model.favoritePaths, [note.path])
        XCTAssertTrue(model.isFavorite(note.path))
        XCTAssertEqual(model.state, .content([note]))
    }

    func testSetFavoriteFalseRemovesLastFavoriteAndPublishesEmpty() async throws {
        let note = makeNote(path: try makePath("Pinned.md"))
        let model = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [note.path] },
                setFavorite: { path, isFavorite in
                    isFavorite ? [path] : []
                }
            )
        )
        await model.load()

        await model.setFavorite(note.path, isFavorite: false)

        XCTAssertEqual(model.favoritePaths, [])
        XCTAssertFalse(model.isFavorite(note.path))
        XCTAssertEqual(model.state, .empty)
    }

    func testWriteFailureKeepsPreviousStableFavoritesAndMapsFixedFailure() async throws {
        let existing = makeNote(path: try makePath("Existing.md"), title: "Existing")
        let attempted = makeNote(path: try makePath("Attempted.md"), title: "Attempted")
        let sensitiveMarker = "private atomic-write failure"
        let model = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [existing, attempted] },
                loadFavoritePaths: { [existing.path] },
                setFavorite: { _, _ in throw PrivateFailure.sensitive(sensitiveMarker) }
            )
        )
        await model.load()

        await model.setFavorite(attempted.path, isFavorite: true)

        XCTAssertEqual(
            model.state,
            .failure(.updateFailed, visibleNotes: [existing])
        )
        XCTAssertEqual(model.favoritePaths, [existing.path])
        XCTAssertTrue(model.isFavorite(existing.path))
        XCTAssertFalse(model.isFavorite(attempted.path))
        XCTAssertFalse(String(reflecting: model.state).contains(sensitiveMarker))
    }

    func testLatestFavoriteOperationWinsWhenOlderWriteFinishesLate() async throws {
        let note = makeNote(path: try makePath("Rapid.md"))
        let source = SuspendedFavoriteWriteSource(note: note)
        let model = FavoritesFeatureModel(source: await source.dataSource)
        await model.load()

        let olderFavorite = Task {
            await model.setFavorite(note.path, isFavorite: true)
        }
        await source.waitUntilFirstWriteStarts()
        let newerUnfavorite = Task {
            await model.setFavorite(note.path, isFavorite: false)
        }
        await newerUnfavorite.value
        await source.resumeFirstWrite()
        await olderFavorite.value

        XCTAssertEqual(model.favoritePaths, [])
        XCTAssertFalse(model.isFavorite(note.path))
        XCTAssertEqual(model.state, .empty)
    }

    func testReloadReintersectsWithLatestIndexWithoutMigratingOrCleaningFavorites() async throws {
        let oldPath = try makePath("Folder/Old.md")
        let renamedPath = try makePath("Folder/Renamed.md")
        let retainedPath = try makePath("Folder/Retained.md")
        let old = makeNote(path: oldPath, title: "Old")
        let renamed = makeNote(path: renamedPath, title: "Renamed")
        let retained = makeNote(path: retainedPath, title: "Retained")
        let source = SequencedFavoritesSource(
            noteLoads: [[old, retained], [renamed, retained]],
            favoritePaths: [oldPath, retainedPath]
        )
        let model = FavoritesFeatureModel(source: await source.dataSource)
        await model.load()
        XCTAssertEqual(model.state, .content([old, retained]))

        await model.reload()

        XCTAssertEqual(model.state, .content([retained]))
        XCTAssertEqual(model.favoritePaths, [oldPath, retainedPath])
        XCTAssertTrue(model.isFavorite(oldPath))
        XCTAssertFalse(model.isFavorite(renamedPath))
        let writeCount = await source.writeCount
        XCTAssertEqual(writeCount, 0)
    }

    func testReloadFailureKeepsPreviousStableFavoritesAndVisibleNotes() async throws {
        let note = makeNote(path: try makePath("Stable.md"))
        let source = FailingFavoritesReloadSource(note: note)
        let model = FavoritesFeatureModel(source: await source.dataSource)
        await model.load()

        await model.reload()

        XCTAssertEqual(
            model.state,
            .failure(.loadFailed, visibleNotes: [note])
        )
        XCTAssertEqual(model.favoritePaths, [note.path])
        XCTAssertTrue(model.isFavorite(note.path))
    }
}

extension FavoritesFeatureModelTests {
    private enum PrivateFailure: Error, Sendable {
        case sensitive(String)
    }

    private func makePath(_ relativePath: String) throws -> VaultPath {
        try VaultPath(decodedRelativePath: relativePath)
    }

    private func makeNote(
        path: VaultPath,
        title: String = "Note",
        modifiedAt: Date = .distantPast
    ) -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: path,
            title: title,
            preview: "Preview",
            modifiedAt: modifiedAt,
            parseStatus: .complete
        )
    }
}

private actor SuspendedFavoriteWriteSource {
    private let note: IndexedNoteSummary
    private var writeCount = 0
    private var firstWriteContinuation: CheckedContinuation<Set<VaultPath>, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var firstWriteStarted = false

    init(note: IndexedNoteSummary) {
        self.note = note
    }

    var dataSource: FavoriteDataSource {
        let capturedNote = note
        return FavoriteDataSource(
            loadNotes: { [capturedNote] in [capturedNote] },
            loadFavoritePaths: { [] },
            setFavorite: { [self] path, isFavorite in
                await write(path, isFavorite: isFavorite)
            }
        )
    }

    func waitUntilFirstWriteStarts() async {
        guard !firstWriteStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeFirstWrite() {
        firstWriteContinuation?.resume(returning: [note.path])
        firstWriteContinuation = nil
    }

    private func write(_ path: VaultPath, isFavorite: Bool) async -> Set<VaultPath> {
        writeCount += 1
        guard writeCount == 1 else {
            return isFavorite ? [path] : []
        }
        firstWriteStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { firstWriteContinuation = $0 }
    }
}

private actor SequencedFavoritesSource {
    private var noteLoads: [[IndexedNoteSummary]]
    private let favoritePaths: Set<VaultPath>
    private(set) var writeCount = 0

    init(noteLoads: [[IndexedNoteSummary]], favoritePaths: Set<VaultPath>) {
        self.noteLoads = noteLoads
        self.favoritePaths = favoritePaths
    }

    var dataSource: FavoriteDataSource {
        FavoriteDataSource(
            loadNotes: { [self] in await nextNotes() },
            loadFavoritePaths: { [self] in favoritePaths },
            setFavorite: { [self] path, isFavorite in
                await write(path, isFavorite: isFavorite)
            }
        )
    }

    private func nextNotes() -> [IndexedNoteSummary] {
        guard noteLoads.count > 1 else { return noteLoads.first ?? [] }
        return noteLoads.removeFirst()
    }

    private func write(_ path: VaultPath, isFavorite: Bool) -> Set<VaultPath> {
        writeCount += 1
        return isFavorite
            ? favoritePaths.union([path])
            : favoritePaths.subtracting([path])
    }
}

private actor FailingFavoritesReloadSource {
    private let note: IndexedNoteSummary
    private var loadCount = 0

    init(note: IndexedNoteSummary) {
        self.note = note
    }

    var dataSource: FavoriteDataSource {
        FavoriteDataSource(
            loadNotes: { [self] in try await loadNotes() },
            loadFavoritePaths: { [note] in [note.path] },
            setFavorite: { [note] _, _ in [note.path] }
        )
    }

    private func loadNotes() throws -> [IndexedNoteSummary] {
        loadCount += 1
        guard loadCount == 1 else {
            throw ReloadFailure.sensitive("private reload details")
        }
        return [note]
    }

    private enum ReloadFailure: Error, Sendable {
        case sensitive(String)
    }
}
