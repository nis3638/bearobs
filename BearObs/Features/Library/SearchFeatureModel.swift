import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct SearchDataSource: Sendable {
    private let operation: @Sendable (String) async throws -> [IndexSearchHit]

    public init(search: @escaping @Sendable (String) async throws -> [IndexSearchHit]) {
        operation = search
    }

    public func search(_ query: String) async throws -> [IndexSearchHit] {
        try await operation(query)
    }

    public static let empty = SearchDataSource { _ in [] }
}

public enum SearchViewState: Equatable, Sendable {
    case loading
    case content([IndexSearchHit])
    case empty
    case failure
}

@MainActor
@Observable
public final class SearchFeatureModel {
    public private(set) var query = ""
    public private(set) var state: SearchViewState = .loading

    private let source: SearchDataSource
    private var operationID = UUID()

    public init(source: SearchDataSource) {
        self.source = source
    }

    public func search(_ query: String) async {
        let previous = state
        let operationID = beginOperation(query: query)
        state = .loading
        do {
            let hits = try await source.search(query)
            guard self.operationID == operationID else { return }
            state = hits.isEmpty ? .empty : .content(hits)
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = previous
        } catch {
            guard self.operationID == operationID else { return }
            state = .failure
        }
    }

    private func beginOperation(query: String) -> UUID {
        let operationID = UUID()
        self.operationID = operationID
        self.query = query
        return operationID
    }
}
