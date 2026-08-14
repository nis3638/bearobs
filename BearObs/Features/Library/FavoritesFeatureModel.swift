import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
#endif

public struct FavoriteDataSource: Sendable {
    private let loadNotesOperation: @Sendable () async throws -> [IndexedNoteSummary]
    private let loadFavoritePathsOperation: @Sendable () async throws -> Set<VaultPath>
    private let setFavoriteOperation: @Sendable (VaultPath, Bool) async throws -> Set<VaultPath>

    public init(
        loadNotes: @escaping @Sendable () async throws -> [IndexedNoteSummary],
        loadFavoritePaths: @escaping @Sendable () async throws -> Set<VaultPath>,
        setFavorite: @escaping @Sendable (VaultPath, Bool) async throws -> Set<VaultPath>
    ) {
        loadNotesOperation = loadNotes
        loadFavoritePathsOperation = loadFavoritePaths
        setFavoriteOperation = setFavorite
    }

    public func loadNotes() async throws -> [IndexedNoteSummary] {
        try await loadNotesOperation()
    }

    public func loadFavoritePaths() async throws -> Set<VaultPath> {
        try await loadFavoritePathsOperation()
    }

    public func setFavorite(
        _ path: VaultPath,
        isFavorite: Bool
    ) async throws -> Set<VaultPath> {
        try await setFavoriteOperation(path, isFavorite)
    }
}

public enum FavoritesFailure: Equatable, Sendable {
    case loadFailed
    case updateFailed
}

public enum FavoritesViewState: Equatable, Sendable {
    case loading
    case content([IndexedNoteSummary])
    case empty
    case failure(FavoritesFailure, visibleNotes: [IndexedNoteSummary])

    public var visibleNotes: [IndexedNoteSummary] {
        switch self {
        case .content(let notes), .failure(_, let notes):
            notes
        case .loading, .empty:
            []
        }
    }
}

@MainActor
@Observable
public final class FavoritesFeatureModel {
    public private(set) var state: FavoritesViewState = .loading
    public private(set) var favoritePaths: Set<VaultPath> = []

    private let source: FavoriteDataSource
    private var indexedNotes: [IndexedNoteSummary] = []
    private var operationID = UUID()

    public init(source: FavoriteDataSource) {
        self.source = source
    }

    public func load() async {
        await loadLatestState()
    }

    public func reload() async {
        await loadLatestState()
    }

    public func setFavorite(_ path: VaultPath, isFavorite: Bool) async {
        let operationID = beginOperation()
        let previousState = state
        let previousFavoritePaths = favoritePaths

        do {
            let favoritePaths = try await source.setFavorite(path, isFavorite: isFavorite)
            guard self.operationID == operationID else { return }
            self.favoritePaths = favoritePaths
            state = Self.loadedState(notes: indexedNotes, favoritePaths: favoritePaths)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            favoritePaths = previousFavoritePaths
            state = previousState
        } catch {
            guard self.operationID == operationID else { return }
            favoritePaths = previousFavoritePaths
            state = .failure(
                .updateFailed,
                visibleNotes: previousState.visibleNotes
            )
        }
    }

    public func isFavorite(_ path: VaultPath) -> Bool {
        favoritePaths.contains(path)
    }

    private func loadLatestState() async {
        let operationID = beginOperation()
        let previousState = state
        if previousState.visibleNotes.isEmpty {
            state = .loading
        }

        do {
            async let notesRequest = source.loadNotes()
            async let favoritePathsRequest = source.loadFavoritePaths()
            let (notes, favoritePaths) = try await (notesRequest, favoritePathsRequest)
            guard self.operationID == operationID else { return }
            indexedNotes = notes
            self.favoritePaths = favoritePaths
            state = Self.loadedState(notes: notes, favoritePaths: favoritePaths)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = previousState
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure(
                .loadFailed,
                visibleNotes: previousState.visibleNotes
            )
        }
    }

    private func beginOperation() -> UUID {
        let operationID = UUID()
        self.operationID = operationID
        return operationID
    }

    private static func loadedState(
        notes: [IndexedNoteSummary],
        favoritePaths: Set<VaultPath>
    ) -> FavoritesViewState {
        let visibleNotes = notes.filter { favoritePaths.contains($0.path) }
        return visibleNotes.isEmpty ? .empty : .content(visibleNotes)
    }
}
