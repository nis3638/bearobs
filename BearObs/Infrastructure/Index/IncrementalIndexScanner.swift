import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsLocalVault
    import BearObsMarkdown
#endif

public struct IncrementalIndexReport: Equatable, Sendable {
    public let metadataSkipped: Int
    public let hashSkipped: Int
    public let indexed: Int
    public let failed: Int
    public let removed: Int

    public init(
        metadataSkipped: Int = 0,
        hashSkipped: Int = 0,
        indexed: Int = 0,
        failed: Int = 0,
        removed: Int = 0
    ) {
        self.metadataSkipped = metadataSkipped
        self.hashSkipped = hashSkipped
        self.indexed = indexed
        self.failed = failed
        self.removed = removed
    }
}

public struct FullIndexRebuildReport: Equatable, Sendable {
    public let indexed: Int
    public let failed: Int

    public init(indexed: Int = 0, failed: Int = 0) {
        self.indexed = indexed
        self.failed = failed
    }
}

public actor IncrementalIndexScanner {
    private let store: LocalVaultStore
    private let repository: SQLiteIndexRepository
    private let limits: MarkdownParseLimits

    public init(
        root: URL,
        repository: SQLiteIndexRepository,
        limits: MarkdownParseLimits = .default
    ) throws {
        store = try LocalVaultStore(root: root)
        self.repository = repository
        self.limits = limits
    }

    public func scan() async throws -> IncrementalIndexReport {
        let files = try store.markdownFiles()
        let stored = try await repository.fingerprints()
        var metadataSkipped = 0
        var hashSkipped = 0
        var indexed = 0
        var failed = 0

        for file in files {
            try Task.checkCancellation()
            if let existing = stored[file.path], isSameMetadata(file, existing) {
                metadataSkipped += 1
                continue
            }

            let snapshot = try store.read(
                file.path,
                maximumRetainedBytes: limits.maximumNoteBytes
            )
            if let existing = stored[file.path],
                existing.contentHash == snapshot.contentHash,
                try await repository.refreshMetadata(
                    for: file.path,
                    matching: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
            {
                hashSkipped += 1
                continue
            }

            guard let data = snapshot.data else {
                try await replaceFailure(snapshot, diagnostic: "markdown.note-too-large")
                failed += 1
                continue
            }
            do {
                let parsed = try MarkdownNoteParser.parse(data, at: file.path, limits: limits)
                let input = try IndexNoteInput(
                    path: file.path,
                    parsedNote: parsed,
                    contentHash: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
                try await repository.replace(input)
                indexed += 1
            } catch let error as MarkdownParseError {
                try await replaceFailure(snapshot, diagnostic: try Self.failureDiagnostic(error))
                failed += 1
            }
        }

        let currentPaths = Set(files.map(\.path))
        let removedPaths = stored.keys.filter { !currentPaths.contains($0) }
        for path in removedPaths {
            try Task.checkCancellation()
            try await repository.remove(path)
        }
        try await repository.resolveAllWikiLinks()
        return IncrementalIndexReport(
            metadataSkipped: metadataSkipped,
            hashSkipped: hashSkipped,
            indexed: indexed,
            failed: failed,
            removed: removedPaths.count
        )
    }

    public func refresh(_ path: VaultPath) async throws {
        try Task.checkCancellation()
        let snapshot = try store.read(
            path,
            maximumRetainedBytes: limits.maximumNoteBytes
        )
        guard let data = snapshot.data else {
            try await replaceFailure(snapshot, diagnostic: "markdown.note-too-large")
            return
        }
        do {
            let parsed = try MarkdownNoteParser.parse(data, at: path, limits: limits)
            try await repository.replaceAndResolveWikiLinks(
                try IndexNoteInput(
                    path: path,
                    parsedNote: parsed,
                    contentHash: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
            )
        } catch let error as MarkdownParseError {
            try await replaceFailure(
                snapshot,
                diagnostic: try Self.failureDiagnostic(error)
            )
        }
    }

    public func rebuild() async throws -> FullIndexRebuildReport {
        let files = try store.markdownFiles()
        let store = self.store
        let limits = self.limits
        let report = try await repository.replaceAll(files) { file in
            try Self.prepare(file, store: store, limits: limits)
        }
        try await repository.resolveAllWikiLinks()
        return report
    }
}

extension IncrementalIndexScanner {
    private func isSameMetadata(
        _ file: LocalVaultFileMetadata,
        _ stored: IndexedNoteFingerprint
    ) -> Bool {
        file.byteSize == stored.byteSize && file.modifiedAt == stored.modifiedAt
    }

    private func replaceFailure(
        _ snapshot: LocalVaultFileSnapshot,
        diagnostic: String
    ) async throws {
        try await repository.replaceFailure(
            at: snapshot.metadata.path,
            contentHash: snapshot.contentHash,
            modifiedAt: snapshot.metadata.modifiedAt,
            byteSize: snapshot.metadata.byteSize,
            diagnostic: diagnostic
        )
    }

    nonisolated private static func prepare(
        _ file: LocalVaultFileMetadata,
        store: LocalVaultStore,
        limits: MarkdownParseLimits
    ) throws -> PreparedIndexEntry {
        let snapshot = try store.read(
            file.path,
            maximumRetainedBytes: limits.maximumNoteBytes
        )
        guard let data = snapshot.data else {
            return failureEntry(snapshot, diagnostic: "markdown.note-too-large")
        }
        do {
            let parsed = try MarkdownNoteParser.parse(data, at: file.path, limits: limits)
            return .note(
                try IndexNoteInput(
                    path: file.path,
                    parsedNote: parsed,
                    contentHash: snapshot.contentHash,
                    modifiedAt: snapshot.metadata.modifiedAt,
                    byteSize: snapshot.metadata.byteSize
                )
            )
        } catch let error as MarkdownParseError {
            return failureEntry(snapshot, diagnostic: try failureDiagnostic(error))
        }
    }

    nonisolated private static func failureEntry(
        _ snapshot: LocalVaultFileSnapshot,
        diagnostic: String
    ) -> PreparedIndexEntry {
        .failure(
            path: snapshot.metadata.path,
            contentHash: snapshot.contentHash,
            modifiedAt: snapshot.metadata.modifiedAt,
            byteSize: snapshot.metadata.byteSize,
            diagnostic: diagnostic
        )
    }

    nonisolated private static func failureDiagnostic(
        _ error: MarkdownParseError
    ) throws -> String {
        switch error {
        case .noteTooLarge:
            "markdown.note-too-large"
        case .invalidUTF8:
            "markdown.invalid-utf8"
        case .invalidLimits:
            throw error
        }
    }
}
