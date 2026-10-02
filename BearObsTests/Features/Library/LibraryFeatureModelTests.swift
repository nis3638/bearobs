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
final class LibraryFeatureModelTests: XCTestCase {
    func testLoadPublishesContentAndEmptyStates() async throws {
        let note = try makeNote()
        let content = LibraryFeatureModel(
            source: LibraryDataSource(load: { [note] }, refresh: {})
        )
        let empty = LibraryFeatureModel(
            source: LibraryDataSource(load: { [] }, refresh: {})
        )

        await content.load()
        await empty.load()

        XCTAssertEqual(content.state, .content([note]))
        XCTAssertEqual(empty.state, .empty)
    }

    func testLoadMapsArbitraryErrorsToFixedFailureCopy() async {
        let model = LibraryFeatureModel(
            source: LibraryDataSource(
                load: { throw PrivateFailure.sensitive("secret path") },
                refresh: {}
            )
        )

        await model.load()

        XCTAssertEqual(model.state, .failure(.loadFailed, visibleNotes: []))
    }

    func testInitialLoadPublishesIndexingStateUntilFirstScanCompletes() async throws {
        let note = try makeNote()
        let source = SuspendedLibrarySource(
            first: [note], second: [note], requiresInitialIndex: true)
        let model = LibraryFeatureModel(source: await source.dataSource)

        let load = Task { await model.load() }
        await source.waitUntilFirstLoadStarts()

        XCTAssertEqual(model.state, .indexing([]))

        await source.resumeFirstLoad()
        await load.value
        XCTAssertEqual(model.state, .content([note]))
    }

    func testRefreshReloadsContentAndReportsFixedFailureWithoutDroppingVisibleNotes() async throws {
        let original = try makeNote(title: "Original")
        let replacement = try makeNote(title: "Replacement")
        let successfulSource = SequencedLibrarySource(
            loads: [[original], [replacement]],
            refreshError: nil
        )
        let success = LibraryFeatureModel(source: await successfulSource.dataSource)
        await success.load()

        await success.refresh()

        XCTAssertEqual(success.state, .content([replacement]))
        let refreshCount = await successfulSource.refreshCount
        XCTAssertEqual(refreshCount, 1)

        let failingSource = SequencedLibrarySource(
            loads: [[original]],
            refreshError: PrivateFailure.sensitive("database details")
        )
        let failure = LibraryFeatureModel(source: await failingSource.dataSource)
        await failure.load()

        await failure.refresh()

        XCTAssertEqual(failure.state, .failure(.refreshFailed, visibleNotes: [original]))
    }

    func testLatestOperationWinsWhenAnOlderLoadFinishesLate() async throws {
        let old = try makeNote(title: "Old")
        let new = try makeNote(title: "New")
        let source = SuspendedLibrarySource(first: [old], second: [new])
        let model = LibraryFeatureModel(source: await source.dataSource)

        let first = Task { await model.load() }
        await source.waitUntilFirstLoadStarts()
        let second = Task { await model.load() }
        await second.value
        await source.resumeFirstLoad()
        await first.value

        XCTAssertEqual(model.state, .content([new]))
    }

    func testCancellationRestoresStableStateAndEmptySourceIsUsable() async throws {
        let empty = LibraryFeatureModel(source: .empty)
        await empty.load()
        XCTAssertEqual(empty.state, .empty)
        XCTAssertEqual(empty.state.visibleNotes, [])

        let note = try makeNote()
        let source = SequencedLibrarySource(loads: [[note]], refreshError: CancellationError())
        let model = LibraryFeatureModel(source: await source.dataSource)
        await model.load()

        await model.refresh()

        XCTAssertEqual(model.state, .content([note]))

        let cancelledLoad = LibraryFeatureModel(
            source: LibraryDataSource(
                load: { throw CancellationError() },
                refresh: {}
            )
        )
        await cancelledLoad.load()
        XCTAssertEqual(cancelledLoad.state, .loading)
    }

    func testLoadPublishesPersistedUnavailableStateWithoutInventingAnEmptyVault() async throws {
        let stalePath = try VaultPath(decodedRelativePath: "Offline.md")
        let staleNote = try makeNote(path: stalePath)
        let model = LibraryFeatureModel(
            source: LibraryDataSource(
                load: { [staleNote] },
                refresh: {},
                availability: {
                    IndexAvailabilityState(
                        unavailableCount: 2,
                        staleNotePaths: [stalePath]
                    )
                }
            )
        )

        await model.load()

        XCTAssertEqual(model.state, .content([staleNote]))
        XCTAssertEqual(model.availability.unavailableCount, 2)
        XCTAssertEqual(model.availability.staleNotePaths, [stalePath])
        XCTAssertEqual(model.availability.diagnostic, .sourceTemporarilyUnavailable)
    }

    func testRefreshClearsRecoveredUnavailableState() async throws {
        let note = try makeNote()
        let source = RecoveringAvailabilitySource(note: note)
        let model = LibraryFeatureModel(source: await source.dataSource)

        await model.load()
        XCTAssertEqual(model.availability.unavailableCount, 1)

        await model.refresh()

        XCTAssertEqual(model.state, .content([note]))
        XCTAssertEqual(model.availability.unavailableCount, 0)
        XCTAssertTrue(model.availability.staleNotePaths.isEmpty)
    }

    func testAvailabilityFailureDoesNotHideSuccessfullyLoadedNotes() async throws {
        let note = try makeNote()
        let model = LibraryFeatureModel(
            source: LibraryDataSource(
                load: { [note] },
                refresh: {},
                availability: { throw PrivateFailure.sensitive("diagnostic database") }
            )
        )

        await model.load()

        XCTAssertEqual(model.state, .content([note]))
        XCTAssertEqual(model.availability.unavailableCount, 0)
    }
}

extension LibraryFeatureModelTests {
    private enum PrivateFailure: Error, Sendable {
        case sensitive(String)
    }

    private func makeNote(
        title: String = "Note",
        path: VaultPath? = nil
    ) throws -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: try path ?? VaultPath(decodedRelativePath: "note.md"),
            title: title,
            preview: "Preview",
            modifiedAt: Date(timeIntervalSince1970: 10),
            parseStatus: .complete
        )
    }
}

private actor RecoveringAvailabilitySource {
    private let note: IndexedNoteSummary
    private var refreshCount = 0

    init(note: IndexedNoteSummary) {
        self.note = note
    }

    var dataSource: LibraryDataSource {
        LibraryDataSource(
            load: { [self] in [note] },
            refresh: { [self] in await recordRefresh() },
            availability: { [self] in await availability() }
        )
    }

    private func recordRefresh() {
        refreshCount += 1
    }

    private func availability() -> IndexAvailabilityState {
        if refreshCount == 0 {
            return IndexAvailabilityState(
                unavailableCount: 1,
                staleNotePaths: [note.path]
            )
        }
        return IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
    }
}

private actor SequencedLibrarySource {
    private var loads: [[IndexedNoteSummary]]
    private let refreshError: (any Error & Sendable)?
    private(set) var refreshCount = 0

    init(loads: [[IndexedNoteSummary]], refreshError: (any Error & Sendable)?) {
        self.loads = loads
        self.refreshError = refreshError
    }

    var dataSource: LibraryDataSource {
        LibraryDataSource(
            load: { [self] in await nextLoad() },
            refresh: { [self] in try await performRefresh() }
        )
    }

    private func nextLoad() -> [IndexedNoteSummary] {
        guard loads.count > 1 else { return loads.first ?? [] }
        return loads.removeFirst()
    }

    private func performRefresh() throws {
        refreshCount += 1
        if let refreshError {
            throw refreshError
        }
    }
}

private actor SuspendedLibrarySource {
    private let first: [IndexedNoteSummary]
    private let second: [IndexedNoteSummary]
    private var loadCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var firstStarted = false
    private let requiresInitialIndex: Bool

    init(
        first: [IndexedNoteSummary],
        second: [IndexedNoteSummary],
        requiresInitialIndex: Bool = false
    ) {
        self.first = first
        self.second = second
        self.requiresInitialIndex = requiresInitialIndex
    }

    var dataSource: LibraryDataSource {
        LibraryDataSource(
            load: { [self] in await load() },
            refresh: {},
            requiresInitialIndex: { [self] in requiresInitialIndex }
        )
    }

    func waitUntilFirstLoadStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeFirstLoad() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func load() async -> [IndexedNoteSummary] {
        loadCount += 1
        guard loadCount == 1 else { return second }
        firstStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { firstContinuation = $0 }
        return first
    }
}
