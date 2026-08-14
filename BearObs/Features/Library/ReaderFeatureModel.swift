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

@MainActor
@Observable
public final class ReaderFeatureModel {
    public let path: VaultPath
    public private(set) var state: ReaderViewState

    private let source: ReaderDataSource
    private var operationID = UUID()

    var dataSource: ReaderDataSource { source }

    public init(
        path: VaultPath,
        source: ReaderDataSource,
        initialState: ReaderViewState = .loading
    ) {
        self.path = path
        self.source = source
        state = initialState
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
