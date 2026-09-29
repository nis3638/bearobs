import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
#endif

public struct EditorDocument: Equatable, Sendable {
    public let text: String
    public let contentHash: ContentHash
    public let sourceInfo: MarkdownSourceInfo
    public let sourceSnapshot: MarkdownSourceSnapshot?

    public init(
        text: String,
        contentHash: ContentHash,
        sourceInfo: MarkdownSourceInfo,
        sourceSnapshot: MarkdownSourceSnapshot? = nil
    ) {
        self.text = text
        self.contentHash = contentHash
        self.sourceInfo = sourceInfo
        self.sourceSnapshot = sourceSnapshot
    }

    public var sourceMap: MarkdownSourceMap? { sourceSnapshot?.sourceMap }

    public static func == (lhs: EditorDocument, rhs: EditorDocument) -> Bool {
        lhs.text == rhs.text
            && lhs.contentHash == rhs.contentHash
            && lhs.sourceInfo == rhs.sourceInfo
    }
}

public struct EditorSaveRequest: Equatable, Sendable {
    public let path: VaultPath
    public let text: String
    public let expectedContentHash: ContentHash
    public let sourceInfo: MarkdownSourceInfo

    public init(
        path: VaultPath,
        text: String,
        expectedContentHash: ContentHash,
        sourceInfo: MarkdownSourceInfo
    ) {
        self.path = path
        self.text = text
        self.expectedContentHash = expectedContentHash
        self.sourceInfo = sourceInfo
    }
}

public struct EditorDataSource: Sendable {
    private let loadOperation: @Sendable (VaultPath) async throws -> EditorDocument
    private let saveOperation: @Sendable (EditorSaveRequest) async throws -> EditorDocument

    public init(
        load: @escaping @Sendable (VaultPath) async throws -> EditorDocument,
        save: @escaping @Sendable (EditorSaveRequest) async throws -> EditorDocument
    ) {
        loadOperation = load
        saveOperation = save
    }

    public func load(_ path: VaultPath) async throws -> EditorDocument {
        try await loadOperation(path)
    }

    public func save(_ request: EditorSaveRequest) async throws -> EditorDocument {
        try await saveOperation(request)
    }
}

public enum EditorDataSourceError: Error, Equatable, Sendable {
    case unavailable
    case contentNotRetained
    case invalidUTF8
    case contentChanged
    case commitUncertain
    case indexRefreshFailed(EditorDocument)
}

public enum EditorFailure: Equatable, Sendable {
    case loadFailed
    case saveFailed
    case contentChanged
    case commitUncertain
    case indexRefreshFailed
}

public enum EditorViewState: Equatable, Sendable {
    case idle
    case loading
    case editing
    case saving
}

@MainActor
@Observable
public final class EditorFeatureModel {
    public let path: VaultPath
    public private(set) var draft = ""
    public private(set) var baselineContentHash: ContentHash?
    public private(set) var sourceInfo: MarkdownSourceInfo?
    public private(set) var sourceSnapshot: MarkdownSourceSnapshot?
    public private(set) var state: EditorViewState = .idle
    public private(set) var failure: EditorFailure?

    private let source: EditorDataSource
    private var baselineBytes = Data()
    private var operationID = UUID()

    public private(set) var draftRevision = 0
    public let projectionEngine: EditorProjectionEngine

    public init(
        path: VaultPath,
        source: EditorDataSource,
        projectionDebounce: Duration = .milliseconds(250),
        projectionBuild:
            @escaping @Sendable (
                String,
                MarkdownSourceSnapshot?
            ) async -> MarkdownEditorProjection? = { text, snapshot in
                MarkdownEditorProjectionBuilder.build(text: text, snapshot: snapshot)
            }
    ) {
        projectionEngine = EditorProjectionEngine(
            debounce: projectionDebounce,
            build: projectionBuild
        )
        self.path = path
        self.source = source
    }

    public var isDirty: Bool {
        baselineContentHash != nil && Data(draft.utf8) != baselineBytes
    }

    public var isLoading: Bool { state == .loading }
    public var isSaving: Bool { state == .saving }
    public var isReady: Bool { baselineContentHash != nil }

    public func updateDraft(_ text: String) {
        // Dirty tracking is byte-level: canonically equivalent but differently
        // encoded text must still count as a draft change, so the no-op guard
        // compares UTF-8 bytes, not canonical String equality.
        guard Data(text.utf8) != Data(draft.utf8) else { return }
        draft = text
        draftRevision += 1
        projectionEngine.scheduleParse(
            revision: draftRevision,
            text: text,
            snapshot: sourceSnapshot
        )
    }

    public func dismissFailure() {
        failure = nil
    }

    public func load() async {
        guard state != .saving else { return }
        let previousState = state
        let operationID = UUID()
        self.operationID = operationID
        state = .loading
        failure = nil
        do {
            let document = try await source.load(path)
            guard self.operationID == operationID else { return }
            publish(document)
            state = .editing
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = previousState
        } catch {
            guard self.operationID == operationID else { return }
            state = .idle
            failure = .loadFailed
        }
    }

    public func save() async {
        guard
            state == .editing,
            isDirty,
            let baselineContentHash,
            let sourceInfo
        else { return }
        let operationID = UUID()
        self.operationID = operationID
        let savedText = draft
        let savedTextBytes = Data(savedText.utf8)
        state = .saving
        failure = nil
        do {
            let document = try await source.save(
                EditorSaveRequest(
                    path: path,
                    text: savedText,
                    expectedContentHash: baselineContentHash,
                    sourceInfo: sourceInfo
                )
            )
            guard self.operationID == operationID else { return }
            adoptSavedDocument(
                document,
                savedTextBytes: savedTextBytes
            )
            state = .editing
        } catch is CancellationError {
            guard self.operationID == operationID else { return }
            state = .editing
        } catch let error as EditorDataSourceError {
            guard self.operationID == operationID else { return }
            state = .editing
            switch error {
            case .contentChanged:
                failure = .contentChanged
            case .commitUncertain:
                failure = .commitUncertain
            case .indexRefreshFailed(let document):
                adoptSavedDocument(
                    document,
                    savedTextBytes: savedTextBytes
                )
                failure = .indexRefreshFailed
            case .unavailable, .contentNotRetained, .invalidUTF8:
                failure = .saveFailed
            }
        } catch {
            guard self.operationID == operationID else { return }
            state = .editing
            failure = .saveFailed
        }
    }

    private func publish(_ document: EditorDocument) {
        draftRevision += 1
        projectionEngine.scheduleParse(
            revision: draftRevision,
            text: document.text,
            snapshot: document.sourceSnapshot
        )
        draft = document.text
        baselineBytes = Data(document.text.utf8)
        baselineContentHash = document.contentHash
        sourceInfo = document.sourceInfo
        sourceSnapshot = document.sourceSnapshot
    }

    private func adoptSavedDocument(
        _ document: EditorDocument,
        savedTextBytes: Data
    ) {
        if Data(draft.utf8) == savedTextBytes {
            draft = document.text
        }
        baselineBytes = Data(document.text.utf8)
        baselineContentHash = document.contentHash
        sourceInfo = document.sourceInfo
        sourceSnapshot = document.sourceSnapshot
    }
}

/// Exclusive states of the draft projection pipeline. Every state carries the
/// draft revision it refers to; only the newest revision's outcome is ever
/// adopted, so a slow parse can never overwrite newer work.
public enum EditorProjectionState: Equatable, Sendable {
    /// No draft revision has been scheduled for parsing yet.
    case idle
    /// The revision is waiting out the debounce or parsing; no result has
    /// landed yet.
    case parsing(revision: Int)
    /// The projection corresponds to the carried revision.
    case ready(revision: Int)
    /// Parsing the carried revision failed; the last valid projection, if
    /// any, stays visible.
    case failed(revision: Int)
}

/// Owns the debounced parse of the draft into its editor projection. Bursts
/// of edits coalesce into one parse per settled revision: scheduling a newer
/// revision cancels the pending wait, the parse itself runs off the main
/// actor, and results whose revision no longer matches are dropped instead
/// of published.
@MainActor
@Observable
public final class EditorProjectionEngine {
    public private(set) var state: EditorProjectionState = .idle
    public private(set) var projection: MarkdownEditorProjection?

    private let debounce: Duration
    private let build:
        @Sendable (
            String,
            MarkdownSourceSnapshot?
        ) async -> MarkdownEditorProjection?
    private var currentRevision = 0
    private var pendingTask: Task<Void, Never>?

    public init(
        debounce: Duration = .milliseconds(250),
        build:
            @escaping @Sendable (
                String,
                MarkdownSourceSnapshot?
            ) async -> MarkdownEditorProjection? = { text, snapshot in
                MarkdownEditorProjectionBuilder.build(text: text, snapshot: snapshot)
            }
    ) {
        self.debounce = debounce
        self.build = build
    }

    /// Records a newer draft revision and schedules its debounced parse.
    /// Older revisions are ignored, and the pending wait of a superseded
    /// revision is cancelled before the newer one starts.
    public func scheduleParse(
        revision: Int,
        text: String,
        snapshot: MarkdownSourceSnapshot?
    ) {
        guard revision > currentRevision else { return }
        currentRevision = revision
        state = .parsing(revision: revision)
        pendingTask?.cancel()
        let debounce = self.debounce
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.parse(revision: revision, text: text, snapshot: snapshot)
        }
    }

    private func parse(
        revision: Int,
        text: String,
        snapshot: MarkdownSourceSnapshot?
    ) async {
        let built = await build(text, snapshot)
        guard revision == currentRevision, !Task.isCancelled else { return }
        if let built {
            projection = built
            state = .ready(revision: revision)
        } else {
            state = .failed(revision: revision)
        }
    }
}
