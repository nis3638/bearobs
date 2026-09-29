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

extension EditorDataSource {
    public static func localVault(
        _ store: LocalVaultStore,
        limits: MarkdownParseLimits = .default,
        didSave: @escaping @Sendable (VaultPath) async throws -> Void = { _ in }
    ) -> EditorDataSource {
        let loader = LocalEditorLoader(store: store, limits: limits, didSave: didSave)
        return EditorDataSource(
            load: { path in try await loader.load(path) },
            save: { request in try await loader.save(request) }
        )
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

private actor LocalEditorLoader {
    let store: LocalVaultStore
    let limits: MarkdownParseLimits
    let didSave: @Sendable (VaultPath) async throws -> Void

    init(
        store: LocalVaultStore,
        limits: MarkdownParseLimits,
        didSave: @escaping @Sendable (VaultPath) async throws -> Void
    ) {
        self.store = store
        self.limits = limits
        self.didSave = didSave
    }

    func load(_ path: VaultPath) throws -> EditorDocument {
        try Task.checkCancellation()
        return try readDocument(path)
    }

    private func readDocument(_ path: VaultPath) throws -> EditorDocument {
        let snapshot = try store.read(
            path,
            maximumRetainedBytes: limits.maximumNoteBytes
        )
        guard let data = snapshot.data else {
            throw EditorDataSourceError.contentNotRetained
        }
        return try makeDocument(
            data: data,
            contentHash: snapshot.contentHash,
            path: path
        )
    }

    private func makeDocument(
        data: Data,
        contentHash: ContentHash,
        path: VaultPath
    ) throws -> EditorDocument {
        let note: ParsedNote
        do {
            note = try MarkdownNoteParser.parse(data, at: path, limits: limits)
        } catch MarkdownParseError.invalidUTF8 {
            throw EditorDataSourceError.invalidUTF8
        }
        let sourceSnapshot: MarkdownSourceSnapshot
        do {
            sourceSnapshot = try MarkdownSourceMapParser.parse(
                data,
                contentHash: contentHash,
                sourceInfo: note.sourceInfo
            )
        } catch MarkdownSourceMapError.invalidUTF8 {
            throw EditorDataSourceError.invalidUTF8
        } catch {
            throw EditorDataSourceError.unavailable
        }
        return EditorDocument(
            text: sourceSnapshot.text,
            contentHash: contentHash,
            sourceInfo: sourceSnapshot.sourceInfo,
            sourceSnapshot: sourceSnapshot
        )
    }

    func save(_ request: EditorSaveRequest) async throws -> EditorDocument {
        try Task.checkCancellation()
        let baselineSnapshot: LocalVaultFileSnapshot
        do {
            baselineSnapshot = try store.read(
                request.path,
                maximumRetainedBytes: limits.maximumNoteBytes
            )
        } catch LocalVaultStoreError.fileChangedDuringRead {
            throw EditorDataSourceError.contentChanged
        }
        guard let baseline = baselineSnapshot.data else {
            throw EditorDataSourceError.contentNotRetained
        }
        guard baselineSnapshot.contentHash == request.expectedContentHash else {
            throw EditorDataSourceError.contentChanged
        }
        let physicalBaseline = try makeDocument(
            data: baseline,
            contentHash: baselineSnapshot.contentHash,
            path: request.path
        )
        guard request.sourceInfo == physicalBaseline.sourceInfo else {
            throw EditorDataSourceError.contentChanged
        }

        let candidate = Self.encode(request.text, sourceInfo: request.sourceInfo)
        guard candidate.count <= limits.maximumNoteBytes else {
            throw EditorDataSourceError.contentNotRetained
        }

        let patched: Data
        do {
            let patches = try MarkdownSourcePatchBuilder.makePatches(
                from: baseline,
                to: candidate
            )
            patched = try MarkdownSourcePatchApplier.apply(patches, to: baseline)
        } catch MarkdownSourcePatchError.invalidUTF8Source {
            throw EditorDataSourceError.invalidUTF8
        } catch {
            throw EditorDataSourceError.unavailable
        }
        guard patched == candidate else {
            throw EditorDataSourceError.unavailable
        }

        if patched == baseline {
            let saved = try makeDocument(
                data: baseline,
                contentHash: baselineSnapshot.contentHash,
                path: request.path
            )
            return saved
        }

        let snapshot: LocalVaultFileSnapshot
        do {
            snapshot = try coordinatedReplace(
                request,
                data: patched
            )
        } catch LocalVaultStoreError.contentChanged {
            throw EditorDataSourceError.contentChanged
        } catch LocalVaultStoreError.atomicWriteFailed(let state) {
            switch state {
            case .notCommitted:
                throw EditorDataSourceError.unavailable
            case .committedButDurabilityUncertain,
                .committedAndDurableButVerificationFailed:
                throw EditorDataSourceError.commitUncertain
            }
        }
        guard let committedData = snapshot.data else {
            throw EditorDataSourceError.commitUncertain
        }
        // replace() verified these committed bytes. Reparse that receipt rather than
        // treating the request text as persisted truth.
        let saved: EditorDocument
        do {
            saved = try makeDocument(
                data: committedData,
                contentHash: snapshot.contentHash,
                path: request.path
            )
        } catch {
            throw EditorDataSourceError.commitUncertain
        }
        do {
            try await didSave(request.path)
        } catch {
            throw EditorDataSourceError.indexRefreshFailed(saved)
        }
        return saved
    }

    private static func encode(
        _ text: String,
        sourceInfo: MarkdownSourceInfo
    ) -> Data {
        let encodedText: String
        switch sourceInfo.lineEnding {
        case .lf:
            encodedText = text
        case .crlf:
            encodedText = normalizedLF(text).replacingOccurrences(of: "\n", with: "\r\n")
        case .none, .mixed:
            encodedText = text
        }
        var data = Data()
        // A leading U+FEFF is indistinguishable from a UTF-8 signature on a cold
        // read. Prefix a signature so the following scalar remains user content.
        if sourceInfo.hasUTF8BOM || text.unicodeScalars.first == "\u{FEFF}" {
            data.append(contentsOf: [0xEF, 0xBB, 0xBF])
        }
        data.append(Data(encodedText.utf8))
        return data
    }

    private static func normalizedLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
    }

    private func coordinatedReplace(
        _ request: EditorSaveRequest,
        data: Data
    ) throws -> LocalVaultFileSnapshot {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<LocalVaultFileSnapshot, Error>?
        coordinator.coordinate(
            writingItemAt: store.coordinatedFileURL(for: request.path),
            options: .forReplacing,
            error: &coordinationError
        ) { _ in
            result = Result {
                try store.replace(
                    request.path,
                    with: data,
                    expectedContentHash: request.expectedContentHash
                )
            }
        }
        if let result { return try result.get() }
        throw LocalVaultStoreError.atomicWriteFailed(.notCommitted)
    }
}
