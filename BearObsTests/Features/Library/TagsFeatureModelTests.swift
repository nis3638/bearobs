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
    func testTagNavigationTreeKeepsFullIdentityWhileRenderingNestedSegments() {
        let tags = [
            IndexedTagSummary(
                normalizedName: "project",
                displayName: "Project",
                noteCount: 2
            ),
            IndexedTagSummary(
                normalizedName: "project/mobile",
                displayName: "Project/Mobile",
                noteCount: 1
            ),
            IndexedTagSummary(
                normalizedName: "project/web",
                displayName: "Project/Web",
                noteCount: 1
            ),
            IndexedTagSummary(
                normalizedName: "solo",
                displayName: "Solo",
                noteCount: 1
            ),
        ]

        let tree = TagNavigationTree.build(from: tags)

        XCTAssertEqual(tree.map(\.normalizedPath), ["project", "solo"])
        XCTAssertEqual(tree[0].displayName, "Project")
        XCTAssertEqual(tree[0].summary?.normalizedName, "project")
        XCTAssertEqual(
            tree[0].children.map(\.normalizedPath),
            ["project/mobile", "project/web"]
        )
        XCTAssertEqual(tree[0].children[0].summary?.normalizedName, "project/mobile")
    }

    func testTagNavigationTreeUsesImplicitParentsOnlyAsNonSelectableGroups() {
        let tree = TagNavigationTree.build(from: [
            IndexedTagSummary(
                normalizedName: "project/mobile",
                displayName: "Project/Mobile",
                noteCount: 1
            )
        ])

        XCTAssertEqual(tree.count, 1)
        XCTAssertEqual(tree[0].normalizedPath, "project")
        XCTAssertEqual(tree[0].displayName, "Project")
        XCTAssertNil(tree[0].summary)
        XCTAssertFalse(tree[0].isSelectable)
        XCTAssertEqual(tree[0].children[0].normalizedPath, "project/mobile")
        XCTAssertEqual(tree[0].children[0].summary?.normalizedName, "project/mobile")
    }

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

    func testTagsModelLoadsSelectedTagAndMapsFailure() async throws {
        let tag = makeTag()
        let note = try makeNote()
        let content = TagsFeatureModel(
            source: TagLibraryDataSource(loadTags: { [tag] }, loadNotes: { _ in [note] })
        )
        let failure = TagsFeatureModel(
            source: TagLibraryDataSource(
                loadTags: { [tag] },
                loadNotes: { _ in throw PrivateFailure.sensitive }
            )
        )

        await content.load()
        await content.select(tag: tag)
        await failure.load()
        await failure.select(tag: tag)

        XCTAssertEqual(content.selectedTag, tag)
        XCTAssertEqual(content.selectedNotesState, .content([note]))
        XCTAssertEqual(failure.selectedTag, tag)
        XCTAssertEqual(failure.selectedNotesState, .failure)
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

    func testLatestSelectedTagNotesWinWhenAnOlderRequestFinishesLate() async throws {
        let firstTag = makeTag(displayName: "First")
        let secondTag = makeTag(displayName: "Second")
        let firstNote = try makeNote(path: "first.md")
        let secondNote = try makeNote(path: "second.md")
        let source = SuspendedTagNotesSource(first: [firstNote], second: [secondNote])
        let model = TagsFeatureModel(source: await source.dataSource)

        let first = Task { await model.select(tag: firstTag) }
        await source.waitUntilFirstNotesLoadStarts()

        let second = Task { await model.select(tag: secondTag) }
        await second.value
        await source.resumeFirstNotesLoad()
        await first.value

        XCTAssertEqual(model.selectedTag, secondTag)
        XCTAssertEqual(model.selectedNotesState, .content([secondNote]))
    }

    func testReloadingTagsClearsSelectionAndNotesWhenSelectedTagDisappears() async throws {
        let tag = makeTag(displayName: "Project")
        let note = try makeNote(path: "project.md")
        let source = SequencedTagSource(
            tagResults: [[tag], []],
            notes: [note]
        )
        let model = TagsFeatureModel(source: await source.dataSource)

        await model.load()
        await model.select(tag: tag)
        await model.load()

        XCTAssertEqual(model.state, .empty)
        XCTAssertNil(model.selectedTag)
        XCTAssertEqual(model.selectedNotesState, .empty)
    }

    func testReloadingTagsRefreshesSelectedSummaryWithoutDiscardingItsNotes() async throws {
        let originalTag = makeTag(displayName: "Project")
        let refreshedTag = IndexedTagSummary(
            normalizedName: originalTag.normalizedName,
            displayName: "Project / Mobile",
            noteCount: 2
        )
        let note = try makeNote(path: "project.md")
        let source = SequencedTagSource(
            tagResults: [[originalTag], [refreshedTag]],
            notes: [note]
        )
        let model = TagsFeatureModel(source: await source.dataSource)

        await model.load()
        await model.select(tag: originalTag)
        await model.load()

        XCTAssertEqual(model.selectedTag, refreshedTag)
        XCTAssertEqual(model.selectedNotesState, .content([note]))
    }

    func testCancellingSelectedTagRestoresPreviousStableSelection() async throws {
        let tag = makeTag(displayName: "Project")
        let note = try makeNote(path: "project.md")
        let source = SequencedNotesSource(first: [note])
        let model = TagsFeatureModel(source: await source.dataSource)

        await model.select(tag: tag)
        await model.select(tag: tag)

        XCTAssertEqual(model.selectedTag, tag)
        XCTAssertEqual(model.selectedNotesState, .content([note]))
    }

    func testCancellingInitialTagSelectionClearsTransientSelection() async {
        let tag = makeTag(displayName: "Project")
        let model = TagsFeatureModel(
            source: TagLibraryDataSource(
                loadTags: { [] },
                loadNotes: { _ in throw CancellationError() }
            )
        )

        await model.select(tag: tag)

        XCTAssertNil(model.selectedTag)
        XCTAssertEqual(model.selectedNotesState, .empty)
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

    private func makeNote(path: String = "note.md") throws -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: try VaultPath(decodedRelativePath: path),
            title: "Note",
            preview: "Preview",
            modifiedAt: .distantPast,
            parseStatus: .complete
        )
    }
}

private actor SuspendedTagNotesSource {
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

    var dataSource: TagLibraryDataSource {
        TagLibraryDataSource(
            loadTags: { [] },
            loadNotes: { [self] _ in await loadNotes() }
        )
    }

    func waitUntilFirstNotesLoadStarts() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeFirstNotesLoad() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func loadNotes() async -> [IndexedNoteSummary] {
        loadCount += 1
        guard loadCount == 1 else { return second }
        firstStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { firstContinuation = $0 }
        return first
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

private actor SequencedTagSource {
    private let tagResults: [[IndexedTagSummary]]
    private let notes: [IndexedNoteSummary]
    private var tagLoadCount = 0

    init(tagResults: [[IndexedTagSummary]], notes: [IndexedNoteSummary]) {
        self.tagResults = tagResults
        self.notes = notes
    }

    var dataSource: TagLibraryDataSource {
        TagLibraryDataSource(
            loadTags: { [self] in await loadTags() },
            loadNotes: { [self] _ in notes }
        )
    }

    private func loadTags() -> [IndexedTagSummary] {
        defer { tagLoadCount += 1 }
        return tagResults[min(tagLoadCount, tagResults.count - 1)]
    }
}

private actor SequencedNotesSource {
    private let first: [IndexedNoteSummary]
    private var loadCount = 0

    init(first: [IndexedNoteSummary]) {
        self.first = first
    }

    var dataSource: TagLibraryDataSource {
        TagLibraryDataSource(
            loadTags: { [] },
            loadNotes: { [self] _ in try await loadNotes() }
        )
    }

    private func loadNotes() throws -> [IndexedNoteSummary] {
        defer { loadCount += 1 }
        guard loadCount == 0 else { throw CancellationError() }
        return first
    }
}
