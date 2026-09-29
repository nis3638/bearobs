import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
#endif

public struct ReaderDataSource: Sendable {
    private let operation: @Sendable (VaultPath) async throws -> MarkdownRenderDocument

    public init(
        load: @escaping @Sendable (VaultPath) async throws -> MarkdownRenderDocument
    ) {
        operation = load
    }

    public func load(_ path: VaultPath) async throws -> MarkdownRenderDocument {
        try await operation(path)
    }

    public static let unavailable = ReaderDataSource { _ in
        throw ReaderDataSourceError.unavailable
    }
}

public struct ReaderWikiLinkDataSource: Sendable {
    private let operation: @Sendable (VaultPath) async throws -> [MarkdownWikiLinkDestination]

    public init(
        load: @escaping @Sendable (VaultPath) async throws -> [MarkdownWikiLinkDestination]
    ) {
        operation = load
    }

    public func load(_ path: VaultPath) async throws -> [MarkdownWikiLinkDestination] {
        try await operation(path)
    }

    public static let empty = ReaderWikiLinkDataSource { _ in [] }
}

public enum ReaderDataSourceError: Error, Equatable, Sendable {
    case unavailable
    case contentNotRetained
}

public enum ReaderViewState: Equatable, Sendable {
    case loading
    case content(MarkdownRenderDocument)
    case failure
}

public enum ReaderFavoriteFailure: Equatable, Sendable {
    case loadFailed
    case updateFailed
}

@MainActor
@Observable
public final class ReaderFeatureModel {
    public let path: VaultPath
    public private(set) var state: ReaderViewState
    public private(set) var favoriteFailure: ReaderFavoriteFailure?
    public private(set) var isUpdatingFavorite = false

    private let source: ReaderDataSource
    private let favorites: FavoritesFeatureModel?
    private var operationID = UUID()
    private var favoriteOperationID = UUID()

    var dataSource: ReaderDataSource { source }
    var favoritesModel: FavoritesFeatureModel? { favorites }
    var hasFavorites: Bool { favorites != nil }

    public init(
        path: VaultPath,
        source: ReaderDataSource,
        initialState: ReaderViewState = .loading,
        favorites: FavoritesFeatureModel? = nil
    ) {
        self.path = path
        self.source = source
        self.favorites = favorites
        state = initialState
        favoriteFailure = nil
    }

    public var isFavorite: Bool {
        favorites?.isFavorite(path) ?? false
    }

    public var favoriteStatusIsReady: Bool {
        favorites?.hasLoaded ?? false
    }

    public func loadFavoriteStatus() async {
        guard let favorites else { return }
        favoriteFailure = nil
        await favorites.loadIfNeeded()
        if !favorites.hasLoaded {
            favoriteFailure = .loadFailed
        }
    }

    public func toggleFavorite() async {
        guard let favorites, !isUpdatingFavorite else { return }
        isUpdatingFavorite = true
        defer { isUpdatingFavorite = false }
        let operationID = UUID()
        favoriteOperationID = operationID
        favoriteFailure = nil
        await favorites.loadIfNeeded()
        guard self.favoriteOperationID == operationID, favorites.hasLoaded else {
            if self.favoriteOperationID == operationID {
                favoriteFailure = .loadFailed
            }
            return
        }
        let result = await favorites.updateFavorite(path, isFavorite: !isFavorite)
        guard self.favoriteOperationID == operationID else { return }
        if result == .failed {
            favoriteFailure = .updateFailed
        }
    }

    public func dismissFavoriteFailure() {
        favoriteFailure = nil
    }

    public func load() async {
        let previous = state
        let operationID = UUID()
        self.operationID = operationID
        state = .loading
        do {
            let document = try await source.load(path)
            guard self.operationID == operationID else { return }
            state = .content(document)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = previous
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure
        }
    }
}
