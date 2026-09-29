import Foundation
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
        let model = try makeModel(debounce: .milliseconds(50)) { text, _ in
            await recorder.record(text)
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
        let model = try makeModel(build: { text, _ in
            await recorder.record(text)
            await gate.hold()
            return MarkdownEditorProjection(text: text, runs: [])
        })

        model.updateDraft("first")
        try await waitUntil { await gate.entryCount == 1 }

        model.updateDraft("second")
        try await waitUntil { await gate.entryCount == 2 }

        await gate.release()
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
        let model = try makeModel(build: { text, _ in
            await recorder.record(text)
            return MarkdownEditorProjection(text: text, runs: [])
        })

        model.updateDraft("same")
        try await waitUntilReady(model)

        model.updateDraft("same")

        XCTAssertEqual(model.draftRevision, 1)
        let parsedTexts = await recorder.texts
        XCTAssertEqual(parsedTexts, ["same"])
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
        document: EditorDocument? = nil
    ) throws -> EditorFeatureModel {
        let document =
            try document
            ?? EditorDocument(
                text: "baseline",
                contentHash: ContentHash(hex: String(repeating: "a", count: 64)),
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
            )
        return EditorFeatureModel(
            path: try VaultPath(decodedRelativePath: "Draft.md"),
            source: EditorDataSource(
                load: { _ in document },
                save: { request in
                    EditorDocument(
                        text: request.text,
                        contentHash: document.contentHash,
                        sourceInfo: request.sourceInfo
                    )
                }
            ),
            projectionDebounce: debounce,
            projectionBuild: build
        )
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

    func record(_ text: String) {
        texts.append(text)
    }

    var parsedTexts: [String] { texts }
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
