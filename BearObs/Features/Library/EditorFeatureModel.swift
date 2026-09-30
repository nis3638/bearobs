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

/// Insertion/selection state in UTF-8 offsets relative to the draft text.
/// `anchor` is the fixed end, `head` the moving end; an insertion point is
/// `anchor == head`. The AppKit adapter converts its `NSRange` to
/// scalar-aligned UTF-8 offsets before calling into the model; the model only
/// clamps to the draft's byte range.
public struct EditorSelection: Equatable, Sendable {
    public let anchorUTF8: Int
    public let headUTF8: Int

    public init(anchorUTF8: Int, headUTF8: Int) {
        self.anchorUTF8 = anchorUTF8
        self.headUTF8 = headUTF8
    }
}

/// Visible-position state in UTF-8 offsets relative to the draft text. The
/// AppKit adapter owns pixel geometry; the model only carries the anchor.
public struct EditorViewport: Equatable, Sendable {
    public let utf8Anchor: Int
    public let verticalOffset: Double

    public init(utf8Anchor: Int, verticalOffset: Double) {
        self.utf8Anchor = utf8Anchor
        self.verticalOffset = verticalOffset
    }
}

/// Immutable snapshot of everything an editor session restores: the draft
/// text, the revision it belongs to, and the selection/viewport state. Every
/// mutation creates a new value; nothing background can hold a mutable
/// collection of editor state (REQ-002 4.3).
public struct EditorDraftSnapshot: Equatable, Sendable {
    public let text: String
    public let revision: Int
    public let selection: EditorSelection
    public let viewport: EditorViewport

    public init(
        text: String,
        revision: Int,
        selection: EditorSelection,
        viewport: EditorViewport
    ) {
        self.text = text
        self.revision = revision
        self.selection = selection
        self.viewport = viewport
    }
}

@MainActor
@Observable
public final class EditorFeatureModel {
    /// One model instance is one editor session: the app creates the model
    /// when the user enters edit mode for `path` and destroys it on switch or
    /// discard, so the session identity is born bound to that path and is
    /// never rebound (REQ-002 6.2/6.4). Async parse results are tagged with
    /// this identity so a superseded session's parse can never publish.
    public let sessionID = UUID()
    public let path: VaultPath
    public private(set) var draft = ""
    public private(set) var baselineContentHash: ContentHash?
    public private(set) var sourceInfo: MarkdownSourceInfo?
    public private(set) var sourceSnapshot: MarkdownSourceSnapshot?
    public private(set) var state: EditorViewState = .idle
    public private(set) var failure: EditorFailure?
    public private(set) var selection = EditorSelection(anchorUTF8: 0, headUTF8: 0)
    public private(set) var viewport = EditorViewport(utf8Anchor: 0, verticalOffset: 0)
    /// True while an input method holds marked (composition) text. The model
    /// must not push any string back out during this window: the view's text
    /// storage holds composition state the draft string cannot represent.
    public private(set) var isMarkedTextActive = false

    private let source: EditorDataSource
    private var baselineBytes = Data()
    private var operationID = UUID()

    public private(set) var draftRevision = 0
    public let projectionEngine: EditorProjectionEngine

    /// Composed fresh on every read, so callers get a value snapshot without
    /// the model ever exposing shared mutable state.
    public var draftSnapshot: EditorDraftSnapshot {
        EditorDraftSnapshot(
            text: draft,
            revision: draftRevision,
            selection: selection,
            viewport: viewport
        )
    }

    public init(
        path: VaultPath,
        source: EditorDataSource,
        projectionDebounce: Duration = .milliseconds(180),
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
            session: sessionID,
            revision: draftRevision,
            text: text,
            snapshot: sourceSnapshot
        )
    }

    public func updateSelection(anchorUTF8: Int, headUTF8: Int) {
        let limit = draft.utf8.count
        selection = EditorSelection(
            anchorUTF8: min(max(0, anchorUTF8), limit),
            headUTF8: min(max(0, headUTF8), limit)
        )
    }

    public func updateViewport(utf8Anchor: Int, verticalOffset: Double) {
        let limit = draft.utf8.count
        viewport = EditorViewport(
            utf8Anchor: min(max(0, utf8Anchor), limit),
            verticalOffset: verticalOffset
        )
    }

    public func setMarkedTextActive(_ active: Bool) {
        isMarkedTextActive = active
    }

    /// The current viewport anchor translated into original-file UTF-8 byte
    /// coordinates (BOM included), so finishing an editing session can hand
    /// the reader a source position to restore (REQ-002 P5). Draft edits
    /// above the anchor shift draft offsets; the baseline mapping is
    /// recovered from the minimal patch between baseline and draft. Nil when
    /// no baseline snapshot exists — nothing can be restored then.
    public var readerRestoreSourceOffset: Int? {
        guard let snapshot = sourceSnapshot else { return nil }
        let baselineOffset = Self.baselineOffset(
            draftOffset: viewport.utf8Anchor,
            baseline: snapshot.text,
            draft: draft
        )
        return baselineOffset + (snapshot.sourceInfo.hasUTF8BOM ? 3 : 0)
    }

    /// Maps a draft offset back to baseline coordinates by inverting the
    /// minimal patch between the two texts: offsets inside a replacement
    /// clamp to the replaced region's start, offsets past the end clamp to
    /// the baseline length.
    static func baselineOffset(draftOffset: Int, baseline: String, draft: String) -> Int {
        guard baseline != draft else {
            return min(max(0, draftOffset), baseline.utf8.count)
        }
        guard
            let patches = try? MarkdownSourcePatchBuilder.makePatches(
                from: Data(baseline.utf8),
                to: Data(draft.utf8)
            )
        else {
            return min(max(0, draftOffset), baseline.utf8.count)
        }
        var shift = 0
        for patch in patches {
            let draftLower = patch.range.lowerBound + shift
            let draftUpper = draftLower + patch.replacement.count
            if draftOffset < draftLower {
                return draftOffset - shift
            }
            if draftOffset < draftUpper {
                return patch.range.lowerBound
            }
            shift += patch.replacement.count - patch.range.count
        }
        return min(max(0, draftOffset - shift), baseline.utf8.count)
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
            session: sessionID,
            revision: draftRevision,
            text: document.text,
            snapshot: document.sourceSnapshot
        )
        draft = document.text
        baselineBytes = Data(document.text.utf8)
        baselineContentHash = document.contentHash
        sourceInfo = document.sourceInfo
        sourceSnapshot = document.sourceSnapshot
        selection = EditorSelection(anchorUTF8: 0, headUTF8: 0)
        viewport = EditorViewport(utf8Anchor: 0, verticalOffset: 0)
    }

    private func adoptSavedDocument(
        _ document: EditorDocument,
        savedTextBytes: Data
    ) {
        // A completed save only moves the baseline (REQ-002 6.4). A
        // higher-revision draft typed while the save was in flight must
        // survive untouched, and while marked text is active the model must
        // never push a string back out that could clobber the composition.
        // The byte check keeps a diverged draft; the string check avoids a
        // no-op write when the saved text is already identical.
        if !isMarkedTextActive,
            Data(draft.utf8) == savedTextBytes,
            draft != document.text
        {
            draft = document.text
        }
        baselineBytes = Data(document.text.utf8)
        baselineContentHash = document.contentHash
        sourceInfo = document.sourceInfo
        sourceSnapshot = document.sourceSnapshot
        // The save returned a fresh sourceSnapshot; re-parse the current
        // draft against it. Scheduling a newer revision also supersedes any
        // pending parse that still used the pre-save snapshot.
        draftRevision += 1
        projectionEngine.scheduleParse(
            session: sessionID,
            revision: draftRevision,
            text: draft,
            snapshot: sourceSnapshot
        )
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
/// of published. Every parse is tagged with the editor session that scheduled
/// it; a result publishes only when both its session and revision still match
/// (REQ-002 6.3), so a superseded session's parse can never land in a newer
/// session and the old session's projection never stays visible under a new
/// note.
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
    private var currentSession = UUID()
    private var currentRevision = 0
    private var pendingTask: Task<Void, Never>?

    public init(
        debounce: Duration = .milliseconds(180),
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

    /// Records a newer draft revision for the given session and schedules its
    /// debounced parse. Older revisions of the same session are ignored. A
    /// session that differs from the current one takes over: its pending
    /// parse is cancelled, the stale projection is cleared, and its revision
    /// space starts fresh.
    public func scheduleParse(
        session: UUID,
        revision: Int,
        text: String,
        snapshot: MarkdownSourceSnapshot?
    ) {
        if session != currentSession {
            currentSession = session
            currentRevision = 0
            pendingTask?.cancel()
            projection = nil
        }
        guard revision > currentRevision else { return }
        currentRevision = revision
        state = .parsing(revision: revision)
        pendingTask?.cancel()
        let debounce = self.debounce
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.parse(
                session: session,
                revision: revision,
                text: text,
                snapshot: snapshot
            )
        }
    }

    private func parse(
        session: UUID,
        revision: Int,
        text: String,
        snapshot: MarkdownSourceSnapshot?
    ) async {
        let built = await build(text, snapshot)
        guard
            session == currentSession,
            revision == currentRevision,
            !Task.isCancelled
        else { return }
        if let built {
            projection = built
            state = .ready(revision: revision)
        } else {
            state = .failed(revision: revision)
        }
    }
}
