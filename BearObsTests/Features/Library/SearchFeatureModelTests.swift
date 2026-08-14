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
final class SearchFeatureModelTests: XCTestCase {
    func testSearchPublishesContentEmptyAndFixedFailure() async throws {
        let hit = try makeHit()
        let content = SearchFeatureModel(
            source: SearchDataSource { query in query.isEmpty ? [hit] : [] }
        )
        let failure = SearchFeatureModel(
            source: SearchDataSource { _ in throw PrivateFailure.sensitive }
        )

        await content.search("")
        XCTAssertEqual(content.state, .content([hit]))

        await content.search("missing")
        XCTAssertEqual(content.state, .empty)

        await failure.search("secret")
        XCTAssertEqual(failure.state, .failure)
    }

    func testLatestQueryWinsWhenOlderSearchFinishesLate() async throws {
        let old = try makeHit(title: "Old")
        let new = try makeHit(title: "New")
        let source = SuspendedSearchSource(old: [old], new: [new])
        let model = SearchFeatureModel(source: await source.dataSource)

        let first = Task { await model.search("old") }
        await source.waitUntilOldSearchStarts()
        let second = Task { await model.search("new") }
        await second.value
        await source.resumeOldSearch()
        await first.value

        XCTAssertEqual(model.query, "new")
        XCTAssertEqual(model.state, .content([new]))
    }

    func testCancellationRestoresPreviousStableResults() async throws {
        let hit = try makeHit()
        let source = SequencedSearchSource(first: [hit])
        let model = SearchFeatureModel(source: await source.dataSource)
        await model.search("")

        await model.search("cancelled")

        XCTAssertEqual(model.state, .content([hit]))
    }
}

extension SearchFeatureModelTests {
    private enum PrivateFailure: Error {
        case sensitive
    }

    private func makeHit(title: String = "Note") throws -> IndexSearchHit {
        IndexSearchHit(
            path: try VaultPath(decodedRelativePath: "\(title).md"),
            title: title,
            preview: "Preview",
            parseStatus: .complete,
            modifiedAt: .distantPast
        )
    }
}

private actor SuspendedSearchSource {
    private let old: [IndexSearchHit]
    private let new: [IndexSearchHit]
    private var oldContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var oldStarted = false

    init(old: [IndexSearchHit], new: [IndexSearchHit]) {
        self.old = old
        self.new = new
    }

    var dataSource: SearchDataSource {
        SearchDataSource { [self] query in await search(query) }
    }

    func waitUntilOldSearchStarts() async {
        guard !oldStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeOldSearch() {
        oldContinuation?.resume()
        oldContinuation = nil
    }

    private func search(_ query: String) async -> [IndexSearchHit] {
        guard query == "old" else { return new }
        oldStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { oldContinuation = $0 }
        return old
    }
}

private actor SequencedSearchSource {
    private let first: [IndexSearchHit]
    private var searchCount = 0

    init(first: [IndexSearchHit]) {
        self.first = first
    }

    var dataSource: SearchDataSource {
        SearchDataSource { [self] _ in try await search() }
    }

    private func search() throws -> [IndexSearchHit] {
        searchCount += 1
        guard searchCount == 1 else { throw CancellationError() }
        return first
    }
}
