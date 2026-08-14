import Foundation
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLocalVault
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

@MainActor
final class ReaderFeatureModelTests: XCTestCase {
    func testLocalVaultSourceReadsParsesAndRendersByCanonicalPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Local title\n\nReadable body.".utf8).write(
            to: root.appendingPathComponent("Local.md")
        )
        let path = try VaultPath(decodedRelativePath: "Local.md")
        let source = ReaderDataSource.localVault(try LocalVaultStore(root: root))

        let document = try await source.load(path)

        XCTAssertEqual(document.title, "Local title")
        XCTAssertEqual(document.blocks.last, .paragraph([.text("Readable body.")]))
    }

    func testLocalVaultSourceUsesResolvedIndexLinksForReaderNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = directory.appendingPathComponent("Vault", isDirectory: true)
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# Source\n\nOpen [[Folder/Target|target]].".utf8).write(
            to: root.appendingPathComponent("Source.md")
        )
        try Data("# Target".utf8).write(to: folder.appendingPathComponent("Target.md"))

        let repository = try SQLiteIndexRepository(
            path: directory.appendingPathComponent("index.sqlite").path
        )
        let scanner = try IncrementalIndexScanner(root: root, repository: repository)
        let report = try await scanner.scan()
        let source = ReaderDataSource.localVault(
            try LocalVaultStore(root: root),
            wikiLinks: .index(repository)
        )

        let document = try await source.load(
            VaultPath(decodedRelativePath: "Source.md")
        )

        XCTAssertEqual(report.indexed, 2)
        XCTAssertEqual(
            document.blocks.last,
            .paragraph([
                .text("Open "),
                .wikiLink(
                    label: "target",
                    target: "Folder/Target",
                    resolution: .resolved(
                        try VaultPath(decodedRelativePath: "Folder/Target.md")
                    )
                ),
                .text("."),
            ])
        )
    }

    func testLoadPublishesContentAndFixedFailure() async throws {
        let path = try VaultPath(decodedRelativePath: "Note.md")
        let document = MarkdownRenderDocument(blocks: [.paragraph([.text("Body")])])
        let content = ReaderFeatureModel(
            path: path,
            source: ReaderDataSource { _ in document }
        )
        let failure = ReaderFeatureModel(
            path: path,
            source: ReaderDataSource { _ in throw PrivateFailure.sensitive }
        )

        await content.load()
        XCTAssertEqual(content.state, .content(document))

        await failure.load()
        XCTAssertEqual(failure.state, .failure)
    }

    func testLatestLoadWinsAndCancellationRestoresStableDocument() async throws {
        let path = try VaultPath(decodedRelativePath: "Note.md")
        let old = MarkdownRenderDocument(blocks: [.paragraph([.text("Old")])])
        let new = MarkdownRenderDocument(blocks: [.paragraph([.text("New")])])
        let source = SuspendedReaderSource(old: old, new: new)
        let model = ReaderFeatureModel(path: path, source: await source.dataSource)

        let first = Task { await model.load() }
        await source.waitUntilFirstLoadStarts()
        let second = Task { await model.load() }
        await second.value
        await source.resumeFirstLoad()
        await first.value
        XCTAssertEqual(model.state, .content(new))

        let cancelled = ReaderFeatureModel(
            path: path,
            source: ReaderDataSource { _ in throw CancellationError() },
            initialState: .content(old)
        )
        await cancelled.load()
        XCTAssertEqual(cancelled.state, .content(old))
    }
}

extension ReaderFeatureModelTests {
    private enum PrivateFailure: Error { case sensitive }
}

private actor SuspendedReaderSource {
    let old: MarkdownRenderDocument
    let new: MarkdownRenderDocument
    private var count = 0
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    init(old: MarkdownRenderDocument, new: MarkdownRenderDocument) {
        self.old = old
        self.new = new
    }

    var dataSource: ReaderDataSource {
        ReaderDataSource { [self] _ in await load() }
    }

    func waitUntilFirstLoadStarts() async {
        if count > 0 { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeFirstLoad() {
        firstContinuation?.resume()
        firstContinuation = nil
    }

    private func load() async -> MarkdownRenderDocument {
        count += 1
        guard count == 1 else { return new }
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { firstContinuation = $0 }
        return old
    }
}
