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
}

extension LibraryFeatureModelTests {
    private enum PrivateFailure: Error, Sendable {
        case sensitive(String)
    }

    private func makeNote(title: String = "Note") throws -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: try VaultPath(decodedRelativePath: "note.md"),
            title: title,
            preview: "Preview",
            modifiedAt: Date(timeIntervalSince1970: 10),
            parseStatus: .complete
        )
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

    init(first: [IndexedNoteSummary], second: [IndexedNoteSummary]) {
        self.first = first
        self.second = second
    }

    var dataSource: LibraryDataSource {
        LibraryDataSource(load: { [self] in await load() }, refresh: {})
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
