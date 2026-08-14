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
final class TagsFeatureModelTests: XCTestCase {
    func testTagsModelPublishesContentEmptyAndFixedFailure() async {
        let tag = makeTag()
        let content = TagsFeatureModel(
            source: TagLibraryDataSource(loadTags: { [tag] }, loadNotes: { _ in [] })
        )
        let empty = TagsFeatureModel(source: .empty)
        let failure = TagsFeatureModel(
            source: TagLibraryDataSource(
                loadTags: { throw PrivateFailure.sensitive },
                loadNotes: { _ in [] }
            )
        )

        await content.load()
        await empty.load()
        await failure.load()

        XCTAssertEqual(content.state, .content([tag]))
        XCTAssertEqual(empty.state, .empty)
        XCTAssertEqual(failure.state, .failure(visibleTags: []))
    }

    func testTaggedNotesModelLoadsSelectedTagAndMapsFailure() async throws {
        let tag = makeTag()
        let note = try makeNote()
        let content = TaggedNotesFeatureModel(
            tag: tag,
            source: TagLibraryDataSource(loadTags: { [] }, loadNotes: { _ in [note] })
        )
        let failure = TaggedNotesFeatureModel(
            tag: tag,
            source: TagLibraryDataSource(
                loadTags: { [] },
                loadNotes: { _ in throw PrivateFailure.sensitive }
            )
        )

        await content.load()
        await failure.load()

        XCTAssertEqual(content.state, .content([note]))
        XCTAssertEqual(failure.state, .failure)
    }

    func testEmptyAndCancelledLoadsRemainExplicitStates() async {
        let tag = makeTag()
        let emptySource = TagLibraryDataSource(loadTags: { [tag] }, loadNotes: { _ in [] })
        let tags = TagsFeatureModel(source: emptySource)
        let notes = tags.notesModel(for: tag)
        let cancelledTags = TagsFeatureModel(
            source: TagLibraryDataSource(
                loadTags: { throw CancellationError() },
                loadNotes: { _ in [] }
            )
        )
        let cancelledNotes = TaggedNotesFeatureModel(
            tag: tag,
            source: TagLibraryDataSource(
                loadTags: { [] },
                loadNotes: { _ in throw CancellationError() }
            )
        )

        await notes.load()
        await cancelledTags.load()
        await cancelledNotes.load()

        XCTAssertEqual(notes.state, .empty)
        XCTAssertEqual(cancelledTags.state, .loading)
        XCTAssertEqual(cancelledNotes.state, .loading)
    }

    func testLatestTagsLoadWinsWhenOlderLoadFinishesLate() async {
        let old = makeTag(displayName: "Old")
        let new = makeTag(displayName: "New")
        let source = SuspendedTagSource(first: [old], second: [new])
        let model = TagsFeatureModel(source: await source.dataSource)

        let first = Task { await model.load() }
        await source.waitUntilFirstLoadStarts()
        let second = Task { await model.load() }
        await second.value
        await source.resumeFirstLoad()
        await first.value

        XCTAssertEqual(model.state, .content([new]))
    }

    func testReloadFailureKeepsPreviouslyVisibleTags() async {
        let tag = makeTag()
        let source = FailingTagReloadSource(tags: [tag])
        let model = TagsFeatureModel(source: await source.dataSource)
        await model.load()

        await model.load()

        XCTAssertEqual(model.state, .failure(visibleTags: [tag]))
    }
}

extension TagsFeatureModelTests {
    private enum PrivateFailure: Error {
        case sensitive
    }

    private func makeTag(displayName: String = "Swift") -> IndexedTagSummary {
        IndexedTagSummary(
            normalizedName: displayName.lowercased(),
            displayName: displayName,
            noteCount: 1
        )
    }

    private func makeNote() throws -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: try VaultPath(decodedRelativePath: "note.md"),
            title: "Note",
            preview: "Preview",
            modifiedAt: .distantPast,
            parseStatus: .complete
        )
    }
}

private actor SuspendedTagSource {
    private let first: [IndexedTagSummary]
    private let second: [IndexedTagSummary]
    private var loadCount = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var firstStarted = false

    init(first: [IndexedTagSummary], second: [IndexedTagSummary]) {
        self.first = first
        self.second = second
    }

    var dataSource: TagLibraryDataSource {
        TagLibraryDataSource(loadTags: { [self] in await load() }, loadNotes: { _ in [] })
    }

    func waitUntilFirstLoadStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeFirstLoad() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func load() async -> [IndexedTagSummary] {
        loadCount += 1
        guard loadCount == 1 else { return second }
        firstStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { firstContinuation = $0 }
        return first
    }
}

private actor FailingTagReloadSource {
    private let tags: [IndexedTagSummary]
    private var hasLoaded = false

    init(tags: [IndexedTagSummary]) {
        self.tags = tags
    }

    var dataSource: TagLibraryDataSource {
        TagLibraryDataSource(loadTags: { [self] in try await load() }, loadNotes: { _ in [] })
    }

    private func load() throws -> [IndexedTagSummary] {
        guard !hasLoaded else { throw ReloadFailure.failed }
        hasLoaded = true
        return tags
    }

    private enum ReloadFailure: Error {
        case failed
    }
}
