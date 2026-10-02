import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct LibraryDataSource: Sendable {
    private let loadOperation: @Sendable () async throws -> [IndexedNoteSummary]
    private let refreshOperation: @Sendable () async throws -> Void
    private let requiresInitialIndexOperation: @Sendable () async -> Bool
    private let availabilityOperation: @Sendable () async throws -> IndexAvailabilityState

    public init(
        load: @escaping @Sendable () async throws -> [IndexedNoteSummary],
        refresh: @escaping @Sendable () async throws -> Void,
        requiresInitialIndex: @escaping @Sendable () async -> Bool = { false },
        availability: @escaping @Sendable () async throws -> IndexAvailabilityState = {
            IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
        }
    ) {
        loadOperation = load
        refreshOperation = refresh
        requiresInitialIndexOperation = requiresInitialIndex
        availabilityOperation = availability
    }

    public func load() async throws -> [IndexedNoteSummary] {
        try await loadOperation()
    }

    public func refresh() async throws {
        try await refreshOperation()
    }

    public func requiresInitialIndex() async -> Bool {
        await requiresInitialIndexOperation()
    }

    public func availability() async throws -> IndexAvailabilityState {
        try await availabilityOperation()
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
    public private(set) var availability = IndexAvailabilityState(
        unavailableCount: 0,
        staleNotePaths: []
    )

    private let source: LibraryDataSource
    private var operationID = UUID()

    public init(source: LibraryDataSource) {
        self.source = source
    }

    public func load() async {
        let operationID = beginOperation()
        let previous = state
        let requiresInitialIndex = await source.requiresInitialIndex()
        guard self.operationID == operationID else { return }
        if previous.visibleNotes.isEmpty {
            state = requiresInitialIndex ? .indexing([]) : .loading
        }
        do {
            let notes = try await source.load()
            guard self.operationID == operationID else { return }
            state = Self.loadedState(notes)
            await updateAvailability(for: operationID)
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
            await updateAvailability(for: operationID)
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

    private func updateAvailability(for operationID: UUID) async {
        do {
            let availability = try await source.availability()
            guard self.operationID == operationID else { return }
            self.availability = availability
        } catch {
            // Availability is advisory metadata. A damaged diagnostic row must
            // never hide note content that was read successfully.
        }
    }

    private static func loadedState(_ notes: [IndexedNoteSummary]) -> LibraryViewState {
        notes.isEmpty ? .empty : .content(notes)
    }
}
