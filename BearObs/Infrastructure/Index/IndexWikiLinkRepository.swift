import Foundation
import GRDB

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
#endif

struct WikiLinkCatalog {
    private let paths: Set<VaultPath>
    private let pathsByFileName: [String: [VaultPath]]

    init(paths: [VaultPath]) {
        self.paths = Set(paths)
        pathsByFileName = Dictionary(grouping: paths, by: Self.fileName)
    }

    func resolve(_ rawTarget: String, from source: VaultPath) -> MarkdownWikiLinkResolution {
        guard let target = normalizedTarget(rawTarget) else { return .missing }
        let hasDirectory = target.contains("/")

        if hasDirectory, let root = candidate(target), paths.contains(root) {
            return .resolved(root)
        }
        if let relative = relativeCandidate(target, from: source), paths.contains(relative) {
            return .resolved(relative)
        }
        if let root = candidate(target), paths.contains(root) {
            return .resolved(root)
        }

        let matches = pathsByFileName[Self.fileName(target)] ?? []
        switch matches.count {
        case 0: return .missing
        case 1: return .resolved(matches[0])
        default: return .ambiguous
        }
    }

    private func normalizedTarget(_ rawTarget: String) -> String? {
        let withoutHeading = rawTarget.split(
            separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let target = withoutHeading.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\\") else {
            return nil
        }
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return target
    }

    private func relativeCandidate(_ target: String, from source: VaultPath) -> VaultPath? {
        let sourceComponents = source.description.split(separator: "/")
        guard sourceComponents.count > 1 else { return nil }
        let parent = sourceComponents.dropLast().joined(separator: "/")
        return candidate("\(parent)/\(target)")
    }

    private func candidate(_ target: String) -> VaultPath? {
        let path = target.lowercased().hasSuffix(".md") ? target : "\(target).md"
        return try? VaultPath(decodedRelativePath: path)
    }

    private static func fileName(_ path: VaultPath) -> String {
        path.description.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func fileName(_ target: String) -> String {
        let name = target.split(separator: "/").last.map(String.init) ?? ""
        return name.lowercased().hasSuffix(".md") ? name : "\(name).md"
    }
}

public enum IndexWikiLinkReadError: Error, Equatable, Sendable {
    case invalidResolutionState(String)
    case missingResolvedPath
    case invalidResolvedPath(String)
}

extension SQLiteIndexRepository {
    public func resolveAllWikiLinks() async throws {
        try Task.checkCancellation()
        try await databasePool.write { database in
            let paths = try String.fetchAll(database, sql: "SELECT path FROM notes").map {
                try VaultPath(decodedRelativePath: $0)
            }
            let catalog = WikiLinkCatalog(paths: paths)
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT id, source_path, raw_target FROM links ORDER BY id"
            )
            for row in rows {
                try Task.checkCancellation()
                let rawSource: String = row["source_path"]
                let rawTarget: String = row["raw_target"]
                let source = try VaultPath(decodedRelativePath: rawSource)
                let resolution = catalog.resolve(rawTarget, from: source)
                try database.execute(
                    sql: """
                        UPDATE links
                        SET resolution_state = ?, resolved_path = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        resolution.databaseState,
                        resolution.resolvedPath?.description,
                        row["id"] as Int64,
                    ]
                )
            }
        }
        try Task.checkCancellation()
    }

    public func wikiLinks(in source: VaultPath) async throws -> [MarkdownWikiLinkDestination] {
        try Task.checkCancellation()
        let links = try await databasePool.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT source_start, source_end, resolution_state, resolved_path
                    FROM links
                    WHERE source_path = ?
                    ORDER BY source_start
                    """,
                arguments: [source.description]
            ).map(Self.decodeWikiLink)
        }
        try Task.checkCancellation()
        return links
    }

    private static func decodeWikiLink(_ row: Row) throws -> MarkdownWikiLinkDestination {
        let state: String = row["resolution_state"]
        let resolution: MarkdownWikiLinkResolution
        switch state {
        case "unresolved": resolution = .unresolved
        case "missing": resolution = .missing
        case "ambiguous": resolution = .ambiguous
        case "resolved":
            guard let rawPath: String = row["resolved_path"] else {
                throw IndexWikiLinkReadError.missingResolvedPath
            }
            guard let path = try? VaultPath(decodedRelativePath: rawPath) else {
                throw IndexWikiLinkReadError.invalidResolvedPath(rawPath)
            }
            resolution = .resolved(path)
        default:
            throw IndexWikiLinkReadError.invalidResolutionState(state)
        }
        return MarkdownWikiLinkDestination(
            sourceRange: (row["source_start"] as Int)..<(row["source_end"] as Int),
            resolution: resolution
        )
    }
}

extension MarkdownWikiLinkResolution {
    fileprivate var databaseState: String {
        switch self {
        case .unresolved: "unresolved"
        case .resolved: "resolved"
        case .missing: "missing"
        case .ambiguous: "ambiguous"
        }
    }

    fileprivate var resolvedPath: VaultPath? {
        guard case .resolved(let path) = self else { return nil }
        return path
    }
}
