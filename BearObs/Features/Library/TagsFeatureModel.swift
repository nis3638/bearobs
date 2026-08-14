import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct TagLibraryDataSource: Sendable {
    private let loadTagsOperation: @Sendable () async throws -> [IndexedTagSummary]
    private let loadNotesOperation:
        @Sendable (IndexedTagSummary) async throws -> [IndexedNoteSummary]

    public init(
        loadTags: @escaping @Sendable () async throws -> [IndexedTagSummary],
        loadNotes: @escaping @Sendable (IndexedTagSummary) async throws -> [IndexedNoteSummary]
    ) {
        loadTagsOperation = loadTags
        loadNotesOperation = loadNotes
    }

    public func loadTags() async throws -> [IndexedTagSummary] {
        try await loadTagsOperation()
    }

    public func loadNotes(for tag: IndexedTagSummary) async throws -> [IndexedNoteSummary] {
        try await loadNotesOperation(tag)
    }

    public static let empty = TagLibraryDataSource(loadTags: { [] }, loadNotes: { _ in [] })
}

public enum TagsViewState: Equatable, Sendable {
    case loading
    case content([IndexedTagSummary])
    case empty
    case failure(visibleTags: [IndexedTagSummary])

    public var visibleTags: [IndexedTagSummary] {
        switch self {
        case .content(let tags), .failure(let tags):
            tags
        case .loading, .empty:
            []
        }
    }
}

public enum TaggedNotesViewState: Equatable, Sendable {
    case loading
    case content([IndexedNoteSummary])
    case empty
    case failure
}

@MainActor
@Observable
public final class TagsFeatureModel {
    public private(set) var state: TagsViewState = .loading

    private let source: TagLibraryDataSource
    private var operationID = UUID()

    public init(source: TagLibraryDataSource) {
        self.source = source
    }

    public func load() async {
        let operationID = beginOperation()
        let previous = state
        if previous.visibleTags.isEmpty {
            state = .loading
        }
        do {
            let tags = try await source.loadTags()
            guard self.operationID == operationID else { return }
            state = tags.isEmpty ? .empty : .content(tags)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = previous
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure(visibleTags: previous.visibleTags)
        }
    }

    public func notesModel(for tag: IndexedTagSummary) -> TaggedNotesFeatureModel {
        TaggedNotesFeatureModel(tag: tag, source: source)
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        self.operationID = operationID
        return operationID
    }
}

@MainActor
@Observable
public final class TaggedNotesFeatureModel {
    public let tag: IndexedTagSummary
    public private(set) var state: TaggedNotesViewState = .loading

    private let source: TagLibraryDataSource
    private var operationID = UUID()

    public init(tag: IndexedTagSummary, source: TagLibraryDataSource) {
        self.tag = tag
        self.source = source
    }

    public func load() async {
        let operationID = beginOperation()
        state = .loading
        do {
            let notes = try await source.loadNotes(for: tag)
            guard self.operationID == operationID else { return }
            state = notes.isEmpty ? .empty : .content(notes)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure
        }
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        self.operationID = operationID
        return operationID
    }
}
