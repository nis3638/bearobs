import Foundation
import Observation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

@MainActor
final class EditorFeatureModelTests: XCTestCase {
    func testUpdateDraftBumpsRevisionAndPublishesProjectionAfterDebounce() async throws {
        let model = try makeModel()

        XCTAssertEqual(model.draftRevision, 0)
        XCTAssertEqual(model.projectionEngine.state, .idle)

        model.updateDraft("edited")

        XCTAssertEqual(model.draftRevision, 1)
        XCTAssertEqual(model.projectionEngine.state, .parsing(revision: 1))
        try await waitUntilReady(model)
        XCTAssertEqual(model.projectionEngine.state, .ready(revision: 1))
        XCTAssertEqual(model.projectionEngine.projection?.text, "edited")
    }

    func testDebounceCoalescesBurstIntoSingleParseOfLatestText() async throws {
        let recorder = BuildRecorder()
        let model = try makeModel(debounce: .milliseconds(50)) { text, snapshot in
            await recorder.record(text, snapshot)
            return MarkdownEditorProjection(text: text, runs: [])
        }

        model.updateDraft("first")
        model.updateDraft("second")
        model.updateDraft("third")

        XCTAssertEqual(model.draftRevision, 3)
        try await waitUntilReady(model)
        let parsedTexts = await recorder.texts
        XCTAssertEqual(parsedTexts, ["third"])
        XCTAssertEqual(model.projectionEngine.state, .ready(revision: 3))
        XCTAssertEqual(model.projectionEngine.projection?.text, "third")
    }

    func testSupersededRevisionParseResultIsDropped() async throws {
        let gate = ParseGate()
        let recorder = BuildRecorder()
        let model = try makeModel(build: { text, snapshot in
            await recorder.record(text, snapshot)
            await gate.hold()
            return MarkdownEditorProjection(text: text, runs: [])
        })

        model.updateDraft("first")
        try await waitUntil { gate.entryCount == 1 }

        model.updateDraft("second")
        try await waitUntil { gate.entryCount == 2 }

        gate.release()
        try await waitUntil { model.projectionEngine.state == .ready(revision: 2) }

        let parsedTexts = await recorder.texts
        XCTAssertEqual(parsedTexts, ["first", "second"])
        XCTAssertEqual(model.projectionEngine.state, .ready(revision: 2))
        XCTAssertEqual(model.projectionEngine.projection?.text, "second")
    }

    func testParseFailureKeepsLastValidProjectionAndReportsFailure() async throws {
        let model = try makeModel(build: { text, _ in
            text == "good" ? MarkdownEditorProjection(text: text, runs: []) : nil
        })

        model.updateDraft("good")
        try await waitUntilReady(model)
        XCTAssertEqual(model.projectionEngine.state, .ready(revision: 1))

        model.updateDraft("bad")
        try await waitUntil {
            model.projectionEngine.state == .failed(revision: 2)
        }

        XCTAssertEqual(model.projectionEngine.state, .failed(revision: 2))
        XCTAssertEqual(model.projectionEngine.projection?.text, "good")
    }

    func testLoadPublishesDocumentRevisionAndSchedulesProjection() async throws {
        let document = EditorDocument(
            text: "loaded",
            contentHash: try ContentHash(hex: String(repeating: "a", count: 64)),
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        )
        let model = try makeModel(document: document)

        await model.load()

        XCTAssertEqual(model.draft, "loaded")
        XCTAssertEqual(model.draftRevision, 1)
        XCTAssertEqual(model.state, .editing)
        try await waitUntilReady(model)
        XCTAssertEqual(model.projectionEngine.state, .ready(revision: 1))
        XCTAssertEqual(model.projectionEngine.projection?.text, "loaded")
    }

    func testEqualDraftDoesNotBumpRevisionOrRescheduleParse() async throws {
        let recorder = BuildRecorder()
        let model = try makeModel(build: { text, snapshot in
            await recorder.record(text, snapshot)
            return MarkdownEditorProjection(text: text, runs: [])
        })

        model.updateDraft("same")
        try await waitUntilReady(model)

        model.updateDraft("same")

        XCTAssertEqual(model.draftRevision, 1)
        let parsedTexts = await recorder.texts
        XCTAssertEqual(parsedTexts, ["same"])
    }

    func testNewInputDuringSaveStaysDirtyAndSurvivesCompletion() async throws {
        let gate = ParseGate()
        let savedHash = try Self.makeHash("b")
        let model = try makeModel(
            document: EditorDocument(
                text: "baseline",
                contentHash: try Self.makeHash("a"),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            ),
            save: { request in
                await gate.hold()
                return EditorDocument(
                    text: request.text,
                    contentHash: savedHash,
                    sourceInfo: request.sourceInfo
                )
            }
        )
        await model.load()

        model.updateDraft("saved text")
        let task = Task { await model.save() }
        try await waitUntil { model.state == .saving }
        try await waitUntil { gate.entryCount == 1 }

        model.updateDraft("typed while saving")

        XCTAssertEqual(model.state, .saving)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.draft, "typed while saving")

        gate.release()
        await task.value

        XCTAssertEqual(model.state, .editing)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.draft, "typed while saving")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.draftRevision, 4)
        try await waitUntil { model.projectionEngine.state == .ready(revision: 4) }
        XCTAssertEqual(model.projectionEngine.projection?.text, "typed while saving")
    }

    func testSaveFailurePreservesDraftSelectionAndViewport() async throws {
        let model = try makeModel(
            document: EditorDocument(
                text: "baseline",
                contentHash: try Self.makeHash("a"),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            ),
            save: { _ in throw EditorDataSourceError.unavailable }
        )
        await model.load()

        model.updateDraft("edited draft")
        model.updateSelection(anchorUTF8: 2, headUTF8: 9)
        model.updateViewport(utf8Anchor: 4, verticalOffset: 12.5)
        let snapshotBeforeSave = model.draftSnapshot

        await model.save()

        XCTAssertEqual(model.state, .editing)
        XCTAssertEqual(model.failure, .saveFailed)
        XCTAssertEqual(model.draft, "edited draft")
        XCTAssertEqual(model.draftSnapshot, snapshotBeforeSave)
    }

    /// REQ-002 P6: retrying after a save failure goes through the same save
    /// path and writes the intact draft — the failure never eats the text.
    func testRetryAfterSaveFailureResavesTheIntactDraft() async throws {
        let savedHash = try Self.makeHash("b")
        let saver = FailingOnceSaver()
        let recorder = SaveRequestRecorder()
        let model = try makeModel(
            document: EditorDocument(
                text: "baseline",
                contentHash: try Self.makeHash("a"),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            ),
            save: { request in
                recorder.record(request.text)
                if saver.shouldFail() {
                    throw EditorDataSourceError.unavailable
                }
                return EditorDocument(
                    text: request.text,
                    contentHash: savedHash,
                    sourceInfo: request.sourceInfo
                )
            }
        )
        await model.load()

        model.updateDraft("重试后仍完整")
        model.updateSelection(anchorUTF8: 2, headUTF8: 4)

        await model.save()

        XCTAssertEqual(model.failure, .saveFailed)
        XCTAssertEqual(model.draft, "重试后仍完整")
        XCTAssertEqual(model.selection, EditorSelection(anchorUTF8: 2, headUTF8: 4))

        await model.save()

        XCTAssertNil(model.failure)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.draft, "重试后仍完整")
        XCTAssertEqual(recorder.texts, ["重试后仍完整", "重试后仍完整"])
    }

    func testSaveCompletionDuringMarkedTextDoesNotForceRewriteDraft() async throws {
        let gate = ParseGate()
        let savedHash = try Self.makeHash("b")
        let model = try makeModel(
            document: EditorDocument(
                text: "baseline",
                contentHash: try Self.makeHash("a"),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            ),
            save: { request in
                await gate.hold()
                return EditorDocument(
                    text: request.text,
                    contentHash: savedHash,
                    sourceInfo: request.sourceInfo
                )
            }
        )
        await model.load()

        model.updateDraft("committed before composition")
        let task = Task { await model.save() }
        try await waitUntil { model.state == .saving }
        try await waitUntil { gate.entryCount == 1 }

        model.setMarkedTextActive(true)
        let flag = ObservationFlag()
        withObservationTracking {
            _ = model.draft
        } onChange: {
            flag.didObserveDraftWrite = true
        }

        gate.release()
        await task.value

        XCTAssertFalse(flag.didObserveDraftWrite)
        XCTAssertEqual(model.draft, "committed before composition")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.state, .editing)
        model.setMarkedTextActive(false)
    }

    func testSaveCompletionAdoptsCanonicalTextAndReprojectsWithNewSnapshot() async throws {
        let gate = ParseGate()
        let recorder = BuildRecorder()
        let savedHash = try Self.makeHash("c")
        let savedInfo = MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        let savedSnapshot = MarkdownSourceSnapshot(
            data: Data("edited text\n".utf8),
            contentHash: savedHash,
            sourceInfo: savedInfo,
            text: "edited text\n",
            sourceMap: MarkdownSourceMap(baselineHash: savedHash, nodes: [])
        )
        let model = try makeModel(
            build: { text, snapshot in
                await recorder.record(text, snapshot)
                return MarkdownEditorProjection(text: text, runs: [])
            },
            document: EditorDocument(
                text: "baseline",
                contentHash: try Self.makeHash("a"),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            ),
            save: { request in
                await gate.hold()
                return EditorDocument(
                    text: request.text + "\n",
                    contentHash: savedHash,
                    sourceInfo: request.sourceInfo,
                    sourceSnapshot: savedSnapshot
                )
            }
        )
        await model.load()

        model.updateSelection(anchorUTF8: 1, headUTF8: 3)
        model.updateViewport(utf8Anchor: 2, verticalOffset: 7)
        let selectionBefore = model.selection
        let viewportBefore = model.viewport

        model.updateDraft("edited text")
        let task = Task { await model.save() }
        try await waitUntil { model.state == .saving }
        try await waitUntil { gate.entryCount == 1 }
        gate.release()
        await task.value

        XCTAssertEqual(model.state, .editing)
        XCTAssertEqual(model.draft, "edited text\n")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.selection, selectionBefore)
        XCTAssertEqual(model.viewport, viewportBefore)
        try await waitUntil { model.projectionEngine.state == .ready(revision: 3) }
        let snapshots = await recorder.snapshots
        XCTAssertEqual(snapshots.last, savedSnapshot)
        let texts = await recorder.texts
        XCTAssertEqual(texts.last, "edited text\n")
    }

    func testSessionSwitchDropsStaleSessionParseResultAndProjection() async throws {
        let gate = ParseGate()
        let engine = EditorProjectionEngine(debounce: .zero) { text, _ in
            await gate.hold()
            return MarkdownEditorProjection(text: text, runs: [])
        }
        let oldSession = UUID()
        let newSession = UUID()

        engine.scheduleParse(session: oldSession, revision: 1, text: "old note", snapshot: nil)
        try await waitUntil { gate.entryCount == 1 }
        gate.release()
        try await waitUntil { engine.state == .ready(revision: 1) }
        XCTAssertEqual(engine.projection?.text, "old note")

        engine.scheduleParse(
            session: oldSession,
            revision: 2,
            text: "old note edited",
            snapshot: nil
        )
        try await waitUntil { gate.entryCount == 1 }

        engine.scheduleParse(session: newSession, revision: 1, text: "new note", snapshot: nil)
        XCTAssertNil(engine.projection)
        XCTAssertEqual(engine.state, .parsing(revision: 1))

        try await waitUntil { gate.entryCount == 2 }
        gate.release()
        try await waitUntil { engine.state == .ready(revision: 1) }
        XCTAssertEqual(engine.projection?.text, "new note")
    }

    func testSessionsOnSharedSourceDoNotCrossPollute() async throws {
        let loadGateA = ParseGate()
        let saveGateA = ParseGate()
        let info = MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        let docA = EditorDocument(
            text: "note A body",
            contentHash: try Self.makeHash("a"),
            sourceInfo: info
        )
        let docB = EditorDocument(
            text: "note B body",
            contentHash: try Self.makeHash("b"),
            sourceInfo: info
        )
        let savedAHash = try Self.makeHash("c")
        let savedBHash = try Self.makeHash("d")
        let pathA = try VaultPath(decodedRelativePath: "A.md")
        let pathB = try VaultPath(decodedRelativePath: "B.md")

        let source = EditorDataSource(
            load: { path in
                if path == pathA {
                    await loadGateA.hold()
                    return docA
                }
                return docB
            },
            save: { request in
                if request.path == pathA {
                    await saveGateA.hold()
                    return EditorDocument(
                        text: request.text,
                        contentHash: savedAHash,
                        sourceInfo: request.sourceInfo
                    )
                }
                return EditorDocument(
                    text: request.text,
                    contentHash: savedBHash,
                    sourceInfo: request.sourceInfo
                )
            }
        )

        let modelA = EditorFeatureModel(path: pathA, source: source)
        let modelB = EditorFeatureModel(path: pathB, source: source)

        let loadA = Task { await modelA.load() }
        try await waitUntil { loadGateA.entryCount == 1 }
        await modelB.load()
        XCTAssertEqual(modelB.draft, "note B body")

        loadGateA.release()
        await loadA.value
        XCTAssertEqual(modelA.draft, "note A body")
        XCTAssertEqual(modelB.draft, "note B body")

        modelA.updateDraft("A edited")
        let saveA = Task { await modelA.save() }
        try await waitUntil { modelA.state == .saving }
        try await waitUntil { saveGateA.entryCount == 1 }

        modelB.updateDraft("B edited")
        await modelB.save()
        XCTAssertEqual(modelB.state, .editing)
        XCTAssertNil(modelB.failure)
        XCTAssertEqual(modelB.draft, "B edited")
        XCTAssertFalse(modelB.isDirty)
        XCTAssertEqual(modelB.baselineContentHash, savedBHash)

        saveGateA.release()
        await saveA.value
        XCTAssertEqual(modelA.state, .editing)
        XCTAssertNil(modelA.failure)
        XCTAssertEqual(modelA.draft, "A edited")
        XCTAssertFalse(modelA.isDirty)
        XCTAssertEqual(modelA.baselineContentHash, savedAHash)
        XCTAssertEqual(modelB.baselineContentHash, savedBHash)
        XCTAssertEqual(modelB.draft, "B edited")
    }

    // MARK: - Reader restore anchor (REQ-002 P5)

    func testReaderRestoreSourceOffsetIsNilWithoutBaselineSnapshot() async throws {
        let model = try makeModel()
        await model.load()

        model.updateViewport(utf8Anchor: 4, verticalOffset: 0)

        XCTAssertNil(
            model.readerRestoreSourceOffset,
            "Without a baseline snapshot there is no source position to restore"
        )
    }

    func testReaderRestoreSourceOffsetMapsCleanDraftDirectly() async throws {
        let baseline = "alpha\nbeta\ngamma\ndelta\n"
        let model = try makeModel(document: Self.makeSnapshotDocument(baseline))
        await model.load()

        let gammaOffset = "alpha\nbeta\n".utf8ByteCount
        model.updateViewport(utf8Anchor: gammaOffset + 2, verticalOffset: 3)

        XCTAssertEqual(model.readerRestoreSourceOffset, gammaOffset + 2)
    }

    func testReaderRestoreSourceOffsetTranslatesEditsAboveTheAnchorBackToBaseline() async throws {
        let baseline = "alpha\nbeta\ngamma\ndelta\n"
        let gammaOffset = "alpha\nbeta\n".utf8ByteCount
        let model = try makeModel(document: Self.makeSnapshotDocument(baseline))
        await model.load()

        // Typed two bytes before the visible area: draft coordinates shift,
        // but the reader reloads baseline bytes, so the anchor must map back.
        model.updateDraft("XX" + baseline)
        let gammaOffsetInDraft = gammaOffset + 2
        model.updateViewport(utf8Anchor: gammaOffsetInDraft + 2, verticalOffset: 0)

        XCTAssertEqual(model.readerRestoreSourceOffset, gammaOffset + 2)
    }

    func testReaderRestoreSourceOffsetTranslatesDeletedPrefixBackToBaseline() async throws {
        let baseline = "alpha\nbeta\ngamma\ndelta\n"
        let deltaOffset = "alpha\nbeta\ngamma\n".utf8ByteCount
        let model = try makeModel(document: Self.makeSnapshotDocument(baseline))
        await model.load()

        // The user deleted everything before the tail; the viewport anchor
        // sits inside the surviving tail, whose content lives further into
        // the baseline than the draft offset suggests.
        model.updateDraft("delta\n")
        model.updateViewport(utf8Anchor: 4, verticalOffset: 0)

        XCTAssertEqual(model.readerRestoreSourceOffset, deltaOffset + 4)
    }

    func testReaderRestoreSourceOffsetAddsBOMShift() async throws {
        let baseline = "alpha\nbeta\n"
        let model = try makeModel(document: Self.makeSnapshotDocument(baseline, hasBOM: true))
        await model.load()

        model.updateViewport(utf8Anchor: 8, verticalOffset: 0)

        XCTAssertEqual(model.readerRestoreSourceOffset, 8 + 3)
    }

    func testReaderRestoreSourceOffsetInsideReplacementClampsToRegionStart() async throws {
        let baseline = "alpha\nbeta\n"
        let model = try makeModel(document: Self.makeSnapshotDocument(baseline))
        await model.load()

        // Rewrote the first word in place: the anchor sits inside the
        // replaced region and clamps to its start.
        model.updateDraft("omega\nbeta\n")
        model.updateViewport(utf8Anchor: 2, verticalOffset: 0)

        XCTAssertEqual(model.readerRestoreSourceOffset, 0)

        // An inserted region's leading boundary keeps its offset — the same
        // boundary rule the forward translation uses — so the anchor
        // attaches to the content before the new bytes.
        model.updateDraft("alphabetical\nbeta\n")
        model.updateViewport(utf8Anchor: 5, verticalOffset: 0)

        XCTAssertEqual(model.readerRestoreSourceOffset, 5)
    }

    private static func makeSnapshotDocument(_ text: String, hasBOM: Bool = false) -> EditorDocument
    {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let data = Data(hasBOM ? bom : []) + Data(text.utf8)
        let snapshot = try! MarkdownSourceMapParser.parse(data)
        return EditorDocument(
            text: snapshot.text,
            contentHash: try! ContentHash(hex: String(repeating: "a", count: 64)),
            sourceInfo: snapshot.sourceInfo,
            sourceSnapshot: snapshot
        )
    }

    private func makeModel(
        debounce: Duration = .zero,
        build:
            @escaping @Sendable (
                String,
                MarkdownSourceSnapshot?
            ) async -> MarkdownEditorProjection? = { text, _ in
                MarkdownEditorProjection(text: text, runs: [])
            },
        document: EditorDocument? = nil,
        save: (@Sendable (EditorSaveRequest) async throws -> EditorDocument)? = nil
    ) throws -> EditorFeatureModel {
        let document =
            try document
            ?? EditorDocument(
                text: "baseline",
                contentHash: ContentHash(hex: String(repeating: "a", count: 64)),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            )
        let saveOperation: @Sendable (EditorSaveRequest) async throws -> EditorDocument
        if let save {
            saveOperation = save
        } else {
            saveOperation = { request in
                EditorDocument(
                    text: request.text,
                    contentHash: document.contentHash,
                    sourceInfo: request.sourceInfo
                )
            }
        }
        return EditorFeatureModel(
            path: try VaultPath(decodedRelativePath: "Draft.md"),
            source: EditorDataSource(
                load: { _ in document },
                save: saveOperation
            ),
            projectionDebounce: debounce,
            projectionBuild: build
        )
    }

    private nonisolated static func makeHash(_ repeated: Character) throws -> ContentHash {
        try ContentHash(hex: String(repeating: repeated, count: 64))
    }

    private func waitUntilReady(
        _ model: EditorFeatureModel,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await waitUntil(timeout: timeout, file: file, line: line) {
            if case .ready = model.projectionEngine.state { true } else { false }
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail(
                    "Timed out waiting for editor projection condition.",
                    file: file,
                    line: line
                )
                return
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

private actor BuildRecorder {
    private(set) var texts: [String] = []
    private(set) var snapshots: [MarkdownSourceSnapshot?] = []

    func record(_ text: String, _ snapshot: MarkdownSourceSnapshot?) {
        texts.append(text)
        snapshots.append(snapshot)
    }
}

private final class ObservationFlag: @unchecked Sendable {
    var didObserveDraftWrite = false
}

/// Save stub that fails exactly once, then succeeds — models the retry path.
private final class FailingOnceSaver: @unchecked Sendable {
    private let lock = NSLock()
    private var hasFailed = false

    func shouldFail() -> Bool {
        lock.withLock {
            if hasFailed { return false }
            hasFailed = true
            return true
        }
    }
}

private final class SaveRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var savedTexts: [String] = []

    var texts: [String] {
        lock.withLock { savedTexts }
    }

    func record(_ text: String) {
        lock.withLock { savedTexts.append(text) }
    }
}

/// Gate for the first parse results so a test can prove that a superseded
/// revision's late result is dropped instead of published.
private final class ParseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var entries = 0
    private var released = false

    var entryCount: Int {
        lock.withLock { entries }
    }

    func hold() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                entries += 1
                if released {
                    continuation.resume()
                } else {
                    continuations.append(continuation)
                }
            }
        }
    }

    func release() {
        lock.withLock {
            released = true
            let waiters = continuations
            continuations = []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

extension String {
    fileprivate var utf8ByteCount: Int { Data(utf8).count }
}
