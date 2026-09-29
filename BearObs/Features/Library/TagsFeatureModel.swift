import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct TagNavigationNode: Equatable, Identifiable, Sendable {
    public let normalizedPath: String
    public let displayName: String
    public let displayPath: String
    public let summary: IndexedTagSummary?
    public let children: [TagNavigationNode]

    public var id: String { normalizedPath }
    public var isSelectable: Bool { summary != nil }

    public init(
        normalizedPath: String,
        displayName: String,
        displayPath: String? = nil,
        summary: IndexedTagSummary?,
        children: [TagNavigationNode]
    ) {
        self.normalizedPath = normalizedPath
        self.displayName = displayName
        self.displayPath = displayPath ?? displayName
        self.summary = summary
        self.children = children
    }
}

public enum TagNavigationTree {
    public static func build(from tags: [IndexedTagSummary]) -> [TagNavigationNode] {
        var recordsByIdentity: [String: TagRecord] = [:]
        for tag in tags {
            guard let record = TagRecord(summary: tag) else { continue }
            if let existing = recordsByIdentity[record.summary.normalizedName] {
                recordsByIdentity[record.summary.normalizedName] =
                    isEarlier(existing, record)
                    ? existing
                    : record
            } else {
                recordsByIdentity[record.summary.normalizedName] = record
            }
        }
        let records = Array(recordsByIdentity.values)
        return buildNodes(records: records, prefix: [])
    }

    private struct TagRecord: Sendable {
        let summary: IndexedTagSummary
        let normalizedParts: [String]
        let displayParts: [String]

        init?(summary: IndexedTagSummary) {
            let normalizedParts = summary.normalizedName
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard
                !normalizedParts.isEmpty,
                normalizedParts.joined(separator: "/") == summary.normalizedName
            else {
                return nil
            }

            let displayParts = summary.displayName
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            self.summary = summary
            self.normalizedParts = normalizedParts
            self.displayParts =
                displayParts.count == normalizedParts.count
                ? displayParts
                : normalizedParts
        }
    }

    private static func buildNodes(
        records: [TagRecord],
        prefix: [String]
    ) -> [TagNavigationNode] {
        let nextSegments = Set(
            records.compactMap { record -> String? in
                guard
                    record.normalizedParts.count > prefix.count,
                    record.normalizedParts.starts(with: prefix)
                else {
                    return nil
                }
                return record.normalizedParts[prefix.count]
            }
        )

        return nextSegments.map { segment in
            let pathParts = prefix + [segment]
            let matchingRecords = records.filter {
                $0.normalizedParts.count >= pathParts.count
                    && $0.normalizedParts.starts(with: pathParts)
            }
            let exactRecord = matchingRecords.first {
                $0.normalizedParts.count == pathParts.count
            }
            let displayName =
                exactRecord?.displayParts[pathParts.count - 1]
                ?? matchingRecords.sorted(by: isEarlier).first?
                .displayParts[pathParts.count - 1]
                ?? segment
            let displayPath =
                exactRecord?.displayParts
                ?? matchingRecords.sorted(by: isEarlier).first?.displayParts
                ?? pathParts

            return TagNavigationNode(
                normalizedPath: pathParts.joined(separator: "/"),
                displayName: displayName,
                displayPath: displayPath.prefix(pathParts.count).joined(separator: "/"),
                summary: exactRecord?.summary,
                children: buildNodes(records: matchingRecords, prefix: pathParts)
            )
        }
        .sorted {
            if $0.displayName != $1.displayName {
                return $0.displayName < $1.displayName
            }
            return $0.normalizedPath < $1.normalizedPath
        }
    }

    private static func isEarlier(_ lhs: TagRecord, _ rhs: TagRecord) -> Bool {
        if lhs.summary.displayName != rhs.summary.displayName {
            return lhs.summary.displayName < rhs.summary.displayName
        }
        return lhs.summary.normalizedName < rhs.summary.normalizedName
    }
}

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

    public var visibleNotes: [IndexedNoteSummary] {
        switch self {
        case .content(let notes):
            notes
        case .loading, .empty, .failure:
            []
        }
    }
}

@MainActor
@Observable
public final class TagsFeatureModel {
    public private(set) var state: TagsViewState = .loading
    public private(set) var selectedTag: IndexedTagSummary?
    public private(set) var selectedNotesState: TaggedNotesViewState = .empty
    public private(set) var hasLoaded = false

    private let source: TagLibraryDataSource
    private var operationID = UUID()
    private var selectedNotesOperationID = UUID()
    private(set) var selectionWasCancelled = false

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
            hasLoaded = true
            reconcileSelectedTag(with: tags)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = previous
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure(visibleTags: previous.visibleTags)
        }
    }

    public func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    public func notesModel(for tag: IndexedTagSummary) -> TaggedNotesFeatureModel {
        TaggedNotesFeatureModel(tag: tag, source: source)
    }

    public func select(tag: IndexedTagSummary) async {
        let previousTag = selectedTag
        let previousNotesState = selectedNotesState
        selectionWasCancelled = false
        selectedTag = tag
        let operationID = beginSelectedNotesOperation()
        selectedNotesState = .loading

        do {
            let notes = try await source.loadNotes(for: tag)
            guard self.selectedNotesOperationID == operationID else { return }
            selectedNotesState = notes.isEmpty ? .empty : .content(notes)
        } catch is CancellationError {
            guard self.selectedNotesOperationID == operationID else { return }
            selectionWasCancelled = true
            selectedTag = previousTag
            selectedNotesState = previousNotesState
        } catch {
            guard self.selectedNotesOperationID == operationID else { return }
            selectedNotesState = .failure
        }
    }

    public func clearTagSelection() {
        selectionWasCancelled = false
        selectedTag = nil
        selectedNotesState = .empty
        selectedNotesOperationID = UUID()
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        self.operationID = operationID
        return operationID
    }

    private func beginSelectedNotesOperation() -> UUID {
        let operationID = UUID()
        selectedNotesOperationID = operationID
        return operationID
    }

    private func reconcileSelectedTag(with tags: [IndexedTagSummary]) {
        guard let selectedTag else { return }
        guard
            let refreshedTag = tags.first(where: {
                $0.normalizedName == selectedTag.normalizedName
            })
        else {
            clearTagSelection()
            return
        }
        self.selectedTag = refreshedTag
    }
}

@MainActor
@Observable
public final class TaggedNotesFeatureModel {
    public let tag: IndexedTagSummary
    public private(set) var state: TaggedNotesViewState = .loading

    // Kept as a source-compatible facade for callers of the pre-REQ001 API.
    // New views use TagsFeatureModel.select(tag:) directly.
    private let selectionModel: TagsFeatureModel

    public init(tag: IndexedTagSummary, source: TagLibraryDataSource) {
        self.tag = tag
        selectionModel = TagsFeatureModel(source: source)
    }

    public func load() async {
        await selectionModel.select(tag: tag)
        state =
            selectionModel.selectionWasCancelled
            ? .loading
            : selectionModel.selectedNotesState
    }
}
