import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLocalVault
    import BearObsMarkdown
#endif

extension ReaderWikiLinkDataSource {
    public static func index(_ repository: SQLiteIndexRepository) -> ReaderWikiLinkDataSource {
        ReaderWikiLinkDataSource { path in
            try await repository.wikiLinks(in: path)
        }
    }
}

extension ReaderDataSource {
    public static func localVault(
        _ store: LocalVaultStore,
        limits: MarkdownParseLimits = .default,
        wikiLinks: ReaderWikiLinkDataSource = .empty
    ) -> ReaderDataSource {
        let loader = LocalReaderLoader(store: store, limits: limits, wikiLinks: wikiLinks)
        return ReaderDataSource { path in
            try await loader.load(path)
        }
    }
}

private actor LocalReaderLoader {
    let store: LocalVaultStore
    let limits: MarkdownParseLimits
    let wikiLinks: ReaderWikiLinkDataSource

    init(
        store: LocalVaultStore,
        limits: MarkdownParseLimits,
        wikiLinks: ReaderWikiLinkDataSource
    ) {
        self.store = store
        self.limits = limits
        self.wikiLinks = wikiLinks
    }

    func load(_ path: VaultPath) async throws -> MarkdownRenderDocument {
        try Task.checkCancellation()
        let snapshot = try store.read(
            path,
            maximumRetainedBytes: limits.maximumNoteBytes
        )
        guard let data = snapshot.data else {
            throw ReaderDataSourceError.contentNotRetained
        }
        let note = try MarkdownNoteParser.parse(data, at: path, limits: limits)
        let destinations = try await wikiLinks.load(path)
        try Task.checkCancellation()
        return MarkdownReaderRenderer.render(note, wikiLinks: destinations)
    }
}
