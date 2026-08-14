import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct LibraryDataSource: Sendable {
    private let loadOperation: @Sendable () async throws -> [IndexedNoteSummary]
    private let refreshOperation: @Sendable () async throws -> Void

    public init(
        load: @escaping @Sendable () async throws -> [IndexedNoteSummary],
        refresh: @escaping @Sendable () async throws -> Void
    ) {
        loadOperation = load
        refreshOperation = refresh
    }

    public func load() async throws -> [IndexedNoteSummary] {
        try await loadOperation()
    }

    public func refresh() async throws {
        try await refreshOperation()
    }

    public static let empty = LibraryDataSource(load: { [] }, refresh: {})
}

public enum LibraryFailure: Equatable, Sendable {
    case loadFailed
    case refreshFailed
}

public enum LibraryViewState: Equatable, Sendable {
    case loading
    case indexing([IndexedNoteSummary])
    case content([IndexedNoteSummary])
    case empty
    case failure(LibraryFailure, visibleNotes: [IndexedNoteSummary])

    public var visibleNotes: [IndexedNoteSummary] {
        switch self {
        case .indexing(let notes), .content(let notes), .failure(_, let notes):
            notes
        case .loading, .empty:
            []
        }
    }
}

@MainActor
@Observable
public final class LibraryFeatureModel {
    public private(set) var state: LibraryViewState = .loading

    private let source: LibraryDataSource
    private var operationID = UUID()

    public init(source: LibraryDataSource) {
        self.source = source
    }

    public func load() async {
        let operationID = beginOperation()
        let previous = state
        if previous.visibleNotes.isEmpty {
            state = .loading
        }
        do {
            let notes = try await source.load()
            guard self.operationID == operationID else { return }
            state = Self.loadedState(notes)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = previous
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure(.loadFailed, visibleNotes: previous.visibleNotes)
        }
    }

    public func refresh() async {
        let operationID = beginOperation()
        let visibleNotes = state.visibleNotes
        state = .indexing(visibleNotes)
        do {
            try await source.refresh()
            let notes = try await source.load()
            guard self.operationID == operationID else { return }
            state = Self.loadedState(notes)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = Self.loadedState(visibleNotes)
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure(.refreshFailed, visibleNotes: visibleNotes)
        }
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        self.operationID = operationID
        return operationID
    }

    private static func loadedState(_ notes: [IndexedNoteSummary]) -> LibraryViewState {
        notes.isEmpty ? .empty : .content(notes)
    }
}
