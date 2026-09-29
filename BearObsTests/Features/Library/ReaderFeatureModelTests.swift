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

    func testReaderLoadsPersistedFavoriteWithoutVisitingFavoritesFirst() async throws {
        let path = try VaultPath(decodedRelativePath: "Recent.md")
        let note = makeNote(path: path)
        let favorites = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [path] },
                setFavorite: { _, _ in [path] }
            )
        )
        let model = ReaderFeatureModel(
            path: path,
            source: .unavailable,
            favorites: favorites
        )

        await model.loadFavoriteStatus()

        XCTAssertTrue(model.isFavorite)
        XCTAssertEqual(favorites.state, .content([note]))
    }

    func testReaderFavoriteToggleUpdatesSharedFavoritesListInBothDirections() async throws {
        let path = try VaultPath(decodedRelativePath: "Recent.md")
        let note = makeNote(path: path)
        let source = InMemoryFavoritesSource(notes: [note])
        let favorites = FavoritesFeatureModel(source: await source.dataSource)
        let model = ReaderFeatureModel(
            path: path,
            source: .unavailable,
            favorites: favorites
        )
        await model.loadFavoriteStatus()

        await model.toggleFavorite()

        XCTAssertTrue(model.isFavorite)
        XCTAssertEqual(favorites.state, .content([note]))
        let firstWrites = await source.recordedWrites()
        XCTAssertEqual(firstWrites, [.init(path: path, isFavorite: true)])

        await model.toggleFavorite()

        XCTAssertFalse(model.isFavorite)
        XCTAssertEqual(favorites.state, .empty)
        let allWrites = await source.recordedWrites()
        XCTAssertEqual(
            allWrites,
            [
                .init(path: path, isFavorite: true),
                .init(path: path, isFavorite: false),
            ]
        )
    }

    func testReaderFavoriteFailureKeepsStableStateAndUsesFixedFailure() async throws {
        let path = try VaultPath(decodedRelativePath: "Stable.md")
        let note = makeNote(path: path)
        let favorites = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [path] },
                setFavorite: { _, _ in throw PrivateFailure.sensitive }
            )
        )
        let model = ReaderFeatureModel(
            path: path,
            source: .unavailable,
            favorites: favorites
        )
        await model.loadFavoriteStatus()

        await model.toggleFavorite()

        XCTAssertTrue(model.isFavorite)
        XCTAssertEqual(model.favoriteFailure, .updateFailed)
        XCTAssertEqual(
            favorites.state,
            .failure(.updateFailed, visibleNotes: [note])
        )
    }

    func testReaderFavoriteCancellationKeepsStableStateWithoutShowingAnError() async throws {
        let path = try VaultPath(decodedRelativePath: "Stable.md")
        let note = makeNote(path: path)
        let favorites = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [path] },
                setFavorite: { _, _ in throw CancellationError() }
            )
        )
        let model = ReaderFeatureModel(
            path: path,
            source: .unavailable,
            favorites: favorites
        )
        await model.loadFavoriteStatus()

        await model.toggleFavorite()

        XCTAssertTrue(model.isFavorite)
        XCTAssertNil(model.favoriteFailure)
        XCTAssertFalse(model.isUpdatingFavorite)
        XCTAssertEqual(favorites.state, .content([note]))
    }

    func testEditorLoadsRawMarkdownAndTracksByteLevelDirtyState() async throws {
        let path = try VaultPath(decodedRelativePath: "Raw.md")
        let baselineHash = try makeHash("a")
        let original = "---\r\ntitle: Raw\r\ncustom: [keep, this]\r\n---\r\n# Café [[Target]]\r\n"
        let document = EditorDocument(
            text: original,
            contentHash: baselineHash,
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: true, lineEnding: .crlf)
        )
        let model = EditorFeatureModel(
            path: path,
            source: EditorDataSource(
                load: { _ in document },
                save: { request in
                    EditorDocument(
                        text: request.text,
                        contentHash: baselineHash,
                        sourceInfo: request.sourceInfo
                    )
                }
            )
        )

        await model.load()

        XCTAssertEqual(model.draft, original)
        XCTAssertEqual(model.baselineContentHash, baselineHash)
        XCTAssertEqual(model.sourceInfo, document.sourceInfo)
        XCTAssertFalse(model.isDirty)

        model.updateDraft(original.replacingOccurrences(of: "Café", with: "Cafe\u{301}"))
        XCTAssertTrue(
            model.isDirty,
            "Dirty tracking must compare UTF-8 bytes, not canonical String equality"
        )

        model.updateDraft(original)
        XCTAssertFalse(model.isDirty)
    }

    func testEditorSaveUsesBaselineHashAndSourceFormatThenPublishesNewBaseline() async throws {
        let path = try VaultPath(decodedRelativePath: "Editable.md")
        let oldHash = try makeHash("b")
        let newHash = try makeHash("c")
        let sourceInfo = MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        let source = RecordingEditorSource(
            loaded: EditorDocument(
                text: "# Before\n",
                contentHash: oldHash,
                sourceInfo: sourceInfo
            ),
            savedHash: newHash
        )
        let model = EditorFeatureModel(path: path, source: await source.dataSource)
        await model.load()
        model.updateDraft("# After\n\nEdited body.\n")

        await model.save()

        let requests = await source.recordedRequests()
        XCTAssertEqual(
            requests,
            [
                EditorSaveRequest(
                    path: path,
                    text: "# After\n\nEdited body.\n",
                    expectedContentHash: oldHash,
                    sourceInfo: sourceInfo
                )
            ]
        )
        XCTAssertEqual(model.draft, "# After\n\nEdited body.\n")
        XCTAssertEqual(model.baselineContentHash, newHash)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(model.failure)
    }

    func testEditorSaveFailureKeepsDraftDirtyAndHidesUnderlyingError() async throws {
        let path = try VaultPath(decodedRelativePath: "Stable.md")
        let baselineHash = try makeHash("d")
        let document = EditorDocument(
            text: "stable",
            contentHash: baselineHash,
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .none)
        )
        let model = EditorFeatureModel(
            path: path,
            source: EditorDataSource(
                load: { _ in document },
                save: { _ in throw PrivateFailure.sensitive }
            )
        )
        await model.load()
        model.updateDraft("unsaved private draft")

        await model.save()

        XCTAssertEqual(model.draft, "unsaved private draft")
        XCTAssertEqual(model.baselineContentHash, baselineHash)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.failure, .saveFailed)
    }

    func testEditorCommitUncertainKeepsOldBaselineAndDirtyDraft() async throws {
        let path = try VaultPath(decodedRelativePath: "Uncertain.md")
        let baselineHash = try makeHash("1")
        let document = EditorDocument(
            text: "baseline",
            contentHash: baselineHash,
            sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .none)
        )
        let model = EditorFeatureModel(
            path: path,
            source: EditorDataSource(
                load: { _ in document },
                save: { _ in throw EditorDataSourceError.commitUncertain }
            )
        )
        await model.load()
        model.updateDraft("possibly saved")

        await model.save()

        XCTAssertEqual(model.baselineContentHash, baselineHash)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.failure, .commitUncertain)
    }

    func testIndexRefreshFailureAdvancesSavedBaselineAndReportsFixedFailure() async throws {
        let path = try VaultPath(decodedRelativePath: "Indexed.md")
        let oldHash = try makeHash("2")
        let savedHash = try makeHash("3")
        let sourceInfo = MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .lf)
        let loaded = EditorDocument(text: "old\n", contentHash: oldHash, sourceInfo: sourceInfo)
        let model = EditorFeatureModel(
            path: path,
            source: EditorDataSource(
                load: { _ in loaded },
                save: { request in
                    throw EditorDataSourceError.indexRefreshFailed(
                        EditorDocument(
                            text: request.text,
                            contentHash: savedHash,
                            sourceInfo: request.sourceInfo
                        )
                    )
                }
            )
        )
        await model.load()
        model.updateDraft("saved\n")

        await model.save()

        XCTAssertEqual(model.baselineContentHash, savedHash)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.failure, .indexRefreshFailed)
    }

    func testEditDuringFailedIndexRefreshKeepsNewerDraftDirty() async throws {
        let path = try VaultPath(decodedRelativePath: "Indexed.md")
        let oldHash = try makeHash("4")
        let savedHash = try makeHash("5")
        let source = SuspendedIndexRefreshFailureSource(
            loaded: EditorDocument(
                text: "baseline",
                contentHash: oldHash,
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .none)
            ),
            savedHash: savedHash
        )
        let model = EditorFeatureModel(path: path, source: await source.dataSource)
        await model.load()
        model.updateDraft("saved draft")

        let save = Task { await model.save() }
        await source.waitUntilSaveStarts()
        model.updateDraft("newer draft")
        await source.resumeWithIndexFailure()
        await save.value

        XCTAssertEqual(model.draft, "newer draft")
        XCTAssertEqual(model.baselineContentHash, savedHash)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.failure, .indexRefreshFailed)
    }

    func testEditDuringSaveRemainsDirtyAfterOlderDraftIsPersisted() async throws {
        let path = try VaultPath(decodedRelativePath: "Concurrent.md")
        let oldHash = try makeHash("e")
        let savedHash = try makeHash("f")
        let source = SuspendedEditorSource(
            loaded: EditorDocument(
                text: "baseline",
                contentHash: oldHash,
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .none)
            ),
            savedHash: savedHash
        )
        let model = EditorFeatureModel(path: path, source: await source.dataSource)
        await model.load()
        model.updateDraft("first draft")

        let save = Task { await model.save() }
        await source.waitUntilSaveStarts()
        model.updateDraft("newer draft")
        await source.resumeSave()
        await save.value

        XCTAssertEqual(model.draft, "newer draft")
        XCTAssertEqual(model.baselineContentHash, savedHash)
        XCTAssertTrue(model.isDirty)
        XCTAssertFalse(model.isSaving)
        XCTAssertNil(model.failure)
    }

    func testLoadDuringSaveCannotReplaceTheDraftOrStrandTheSavingState() async throws {
        let path = try VaultPath(decodedRelativePath: "Concurrent.md")
        let oldHash = try makeHash("8")
        let savedHash = try makeHash("9")
        let source = SuspendedEditorSource(
            loaded: EditorDocument(
                text: "baseline",
                contentHash: oldHash,
                sourceInfo: MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .none)
            ),
            savedHash: savedHash
        )
        let model = EditorFeatureModel(path: path, source: await source.dataSource)
        await model.load()
        model.updateDraft("saved draft")

        let save = Task { await model.save() }
        await source.waitUntilSaveStarts()
        await model.load()

        XCTAssertEqual(model.draft, "saved draft")
        XCTAssertEqual(model.state, .saving)
        await source.resumeSave()
        await save.value
        XCTAssertEqual(model.state, .editing)
        XCTAssertEqual(model.draft, "saved draft")
        XCTAssertFalse(model.isDirty)
    }

    func testEditorUsesTheReturnedDocumentAsTheNewBaseline() async throws {
        let path = try VaultPath(decodedRelativePath: "Normalized.md")
        let oldHash = try makeHash("6")
        let savedHash = try makeHash("7")
        let sourceInfo = MarkdownSourceInfo(hasUTF8BOM: false, lineEnding: .crlf)
        let model = EditorFeatureModel(
            path: path,
            source: EditorDataSource(
                load: { _ in
                    EditorDocument(
                        text: "old\r\n",
                        contentHash: oldHash,
                        sourceInfo: sourceInfo
                    )
                },
                save: { _ in
                    EditorDocument(
                        text: "persisted\r\n",
                        contentHash: savedHash,
                        sourceInfo: sourceInfo
                    )
                }
            )
        )
        await model.load()
        model.updateDraft("persisted\n")

        await model.save()

        XCTAssertEqual(model.draft, "persisted\r\n")
        XCTAssertEqual(model.baselineContentHash, savedHash)
        XCTAssertFalse(model.isDirty)
    }

    func testLocalEditorPreservesBOMCRLFAndUnchangedFrontmatter() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try VaultPath(decodedRelativePath: "Raw.md")
        let url = root.appendingPathComponent(path.description)
        let prefix = "---\r\ntitle: Raw\r\ncustom: [keep, this]\r\n---\r\n"
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("\(prefix)# Before\r\n".utf8)
        try original.write(to: url)
        let source = EditorDataSource.localVault(try LocalVaultStore(root: root))
        let loaded = try await source.load(path)

        let saved = try await source.save(
            EditorSaveRequest(
                path: path,
                text: "\(prefix)# After\n\nEdited.\n",
                expectedContentHash: loaded.contentHash,
                sourceInfo: loaded.sourceInfo
            )
        )

        let expected =
            Data([0xEF, 0xBB, 0xBF])
            + Data("\(prefix)# After\r\n\r\nEdited.\r\n".utf8)
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertEqual(saved.sourceInfo, .init(hasUTF8BOM: true, lineEnding: .crlf))
    }

    func testLocalEditorPreservesLoneCarriageReturnInLFFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try VaultPath(decodedRelativePath: "LineEndings.md")
        let url = root.appendingPathComponent(path.description)
        try Data("keep\rthis\n".utf8).write(to: url)
        let source = EditorDataSource.localVault(try LocalVaultStore(root: root))
        let loaded = try await source.load(path)

        _ = try await source.save(
            EditorSaveRequest(
                path: path,
                text: "keep\rthis\nnew line\n",
                expectedContentHash: loaded.contentHash,
                sourceInfo: loaded.sourceInfo
            )
        )

        XCTAssertEqual(try Data(contentsOf: url), Data("keep\rthis\nnew line\n".utf8))
    }

    func testLocalEditorDoesNotDropAUserInsertedLeadingByteOrderMarkScalar() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try VaultPath(decodedRelativePath: "Scalar.md")
        let url = root.appendingPathComponent(path.description)
        try Data("baseline".utf8).write(to: url)
        let source = EditorDataSource.localVault(try LocalVaultStore(root: root))
        let loaded = try await source.load(path)

        let saved = try await source.save(
            EditorSaveRequest(
                path: path,
                text: "\u{FEFF}baseline",
                expectedContentHash: loaded.contentHash,
                sourceInfo: loaded.sourceInfo
            )
        )

        let bom = Data([0xEF, 0xBB, 0xBF])
        XCTAssertEqual(try Data(contentsOf: url), bom + Data("\u{FEFF}baseline".utf8))
        XCTAssertEqual(saved.text, "\u{FEFF}baseline")
        XCTAssertTrue(saved.sourceInfo.hasUTF8BOM)

        let savedAgain = try await source.save(
            EditorSaveRequest(
                path: path,
                text: "\u{FEFF}baseline edited",
                expectedContentHash: saved.contentHash,
                sourceInfo: saved.sourceInfo
            )
        )
        XCTAssertEqual(savedAgain.text, "\u{FEFF}baseline edited")
        XCTAssertTrue(savedAgain.sourceInfo.hasUTF8BOM)
        XCTAssertEqual(
            try Data(contentsOf: url),
            bom + Data("\u{FEFF}baseline edited".utf8)
        )

        let reloadedSource = EditorDataSource.localVault(try LocalVaultStore(root: root))
        let loadedAgain = try await reloadedSource.load(path)
        XCTAssertEqual(loadedAgain.text, "\u{FEFF}baseline edited")
        XCTAssertTrue(loadedAgain.sourceInfo.hasUTF8BOM)
    }

    func testLocalEditorRejectsSourceFormatThatDoesNotMatchTheBaseline() async throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("before\r\n".utf8)
        let fixture = try LocalEditorFixture(data: original)
        defer { fixture.remove() }
        let loaded = try await fixture.source.load(fixture.path)

        do {
            _ = try await fixture.source.save(
                EditorSaveRequest(
                    path: fixture.path,
                    text: "after\n",
                    expectedContentHash: loaded.contentHash,
                    sourceInfo: .init(hasUTF8BOM: false, lineEnding: .lf)
                )
            )
            XCTFail("Expected mismatched source metadata to be rejected")
        } catch {
            XCTAssertEqual(error as? EditorDataSourceError, .contentChanged)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), original)
    }

    func testLocalEditorTreatsPostCommitCancellationAsIndexRefreshFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try VaultPath(decodedRelativePath: "Cancelled.md")
        let url = root.appendingPathComponent(path.description)
        try Data("before".utf8).write(to: url)
        let store = try LocalVaultStore(root: root)
        let source = EditorDataSource.localVault(
            store,
            didSave: { _ in throw CancellationError() }
        )
        let loaded = try await source.load(path)

        do {
            _ = try await source.save(
                EditorSaveRequest(
                    path: path,
                    text: "after",
                    expectedContentHash: loaded.contentHash,
                    sourceInfo: loaded.sourceInfo
                )
            )
            XCTFail("Expected the post-commit refresh failure")
        } catch EditorDataSourceError.indexRefreshFailed(let saved) {
            XCTAssertEqual(saved.text, "after")
            XCTAssertNotEqual(saved.contentHash, loaded.contentHash)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: url), Data("after".utf8))
    }

    func testLocalEditorRejectsExternalEditWithoutOverwritingIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try VaultPath(decodedRelativePath: "Conflict.md")
        let url = root.appendingPathComponent(path.description)
        try Data("baseline".utf8).write(to: url)
        let model = EditorFeatureModel(
            path: path,
            source: .localVault(try LocalVaultStore(root: root))
        )
        await model.load()
        let baselineHash = model.baselineContentHash
        try Data("external edit".utf8).write(to: url)
        model.updateDraft("stale draft")

        await model.save()

        XCTAssertEqual(try Data(contentsOf: url), Data("external edit".utf8))
        XCTAssertEqual(model.baselineContentHash, baselineHash)
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.failure, .contentChanged)
    }

    func testLocalEditorLoadPublishesTheExactSourceSnapshot() async throws {
        let fixture = try LocalEditorFixture(
            data: Data([0xEF, 0xBB, 0xBF]) + Data("---\r\ntitle: Raw\r\n---\r\n正文🐻\r\n".utf8)
        )
        defer { fixture.remove() }

        let document = try await fixture.source.load(fixture.path)

        let sourceSnapshot = try XCTUnwrap(document.sourceSnapshot)
        XCTAssertEqual(sourceSnapshot.data, fixture.originalData)
        XCTAssertEqual(sourceSnapshot.contentHash, document.contentHash)
        XCTAssertEqual(sourceSnapshot.sourceMap.baselineHash, document.contentHash)
        XCTAssertEqual(sourceSnapshot.text, document.text)
    }

    func testLocalEditorNoOpSaveDoesNotRewriteOrRefreshIndex() async throws {
        let fixture = try LocalEditorFixture(
            data: Data([0xEF, 0xBB, 0xBF])
                + Data("---\r\ncustom: keep\r\n---\r\n<!-- keep -->\r\nplugin:: keep\r\n".utf8)
        )
        defer { fixture.remove() }
        let refreshes = SaveRefreshRecorder()
        let source = EditorDataSource.localVault(
            fixture.store,
            didSave: { path in await refreshes.record(path) }
        )
        let loaded = try await source.load(fixture.path)
        let modifiedBefore = try fixture.modifiedAt()

        let saved = try await source.save(
            EditorSaveRequest(
                path: fixture.path,
                text: loaded.text,
                expectedContentHash: loaded.contentHash,
                sourceInfo: loaded.sourceInfo
            )
        )

        XCTAssertEqual(try Data(contentsOf: fixture.url), fixture.originalData)
        XCTAssertEqual(try fixture.modifiedAt(), modifiedBefore)
        let refreshedPaths = await refreshes.paths()
        XCTAssertEqual(refreshedPaths, [])
        XCTAssertEqual(saved.contentHash, loaded.contentHash)
        XCTAssertEqual(saved.sourceSnapshot?.data, fixture.originalData)
    }

    func testLocalEditorChangesOnlyTheEditedParagraphBytes() async throws {
        let originalText =
            "---\r\ntitle: Keep\r\ncustom: 'same'\r\n---\r\n\r\n"
            + "普通段落 old word。\r\n\r\n"
            + "> [!note]+ Keep\r\n> callout\r\n\r\n"
            + "```dataview\r\nTABLE file.name\r\n```\r\n"
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(originalText.utf8)
        let fixture = try LocalEditorFixture(data: original)
        defer { fixture.remove() }
        let loaded = try await fixture.source.load(fixture.path)

        let saved = try await fixture.source.save(
            EditorSaveRequest(
                path: fixture.path,
                text: loaded.text.replacingOccurrences(of: "old word", with: "新词"),
                expectedContentHash: loaded.contentHash,
                sourceInfo: loaded.sourceInfo
            )
        )

        let expected = original.replacing(
            Data("old word".utf8),
            with: Data("新词".utf8)
        )
        XCTAssertEqual(try Data(contentsOf: fixture.url), expected)
        XCTAssertEqual(saved.sourceSnapshot?.data, expected)
        XCTAssertNotEqual(saved.contentHash, loaded.contentHash)
        XCTAssertEqual(saved.sourceMap?.baselineHash, saved.contentHash)
    }

    func testLocalEditorTaskToggleChangesOnlyTheTaskMarker() async throws {
        let original = Data("  - [ ] 第一项 ^keep\r\n* [x] 第二项\r\n".utf8)
        let fixture = try LocalEditorFixture(data: original)
        defer { fixture.remove() }
        let loaded = try await fixture.source.load(fixture.path)

        _ = try await fixture.source.save(
            EditorSaveRequest(
                path: fixture.path,
                text: loaded.text.replacingOccurrences(of: "[ ]", with: "[x]"),
                expectedContentHash: loaded.contentHash,
                sourceInfo: loaded.sourceInfo
            )
        )

        XCTAssertEqual(
            try Data(contentsOf: fixture.url),
            Data("  - [x] 第一项 ^keep\r\n* [x] 第二项\r\n".utf8)
        )
    }
}

extension ReaderFeatureModelTests {
    private enum PrivateFailure: Error { case sensitive }

    private func makeNote(path: VaultPath) -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: path,
            title: path.fileNameWithoutExtension,
            preview: "Preview",
            modifiedAt: .distantPast,
            parseStatus: .complete
        )
    }

    private func makeHash(_ digit: Character) throws -> ContentHash {
        try ContentHash(hex: String(repeating: digit, count: 64))
    }
}

private struct FavoriteWrite: Equatable, Sendable {
    let path: VaultPath
    let isFavorite: Bool
}

private actor InMemoryFavoritesSource {
    private let notes: [IndexedNoteSummary]
    private var paths: Set<VaultPath> = []
    private(set) var writes: [FavoriteWrite] = []

    init(notes: [IndexedNoteSummary]) {
        self.notes = notes
    }

    var dataSource: FavoriteDataSource {
        FavoriteDataSource(
            loadNotes: { [self] in notes },
            loadFavoritePaths: { [self] in await favoritePaths() },
            setFavorite: { [self] path, isFavorite in
                await setFavorite(path, isFavorite: isFavorite)
            }
        )
    }

    func recordedWrites() -> [FavoriteWrite] {
        writes
    }

    private func favoritePaths() -> Set<VaultPath> {
        paths
    }

    private func setFavorite(_ path: VaultPath, isFavorite: Bool) -> Set<VaultPath> {
        writes = writes + [FavoriteWrite(path: path, isFavorite: isFavorite)]
        paths = isFavorite ? paths.union([path]) : paths.subtracting([path])
        return paths
    }
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

private actor RecordingEditorSource {
    let loaded: EditorDocument
    let savedHash: ContentHash
    private var requests: [EditorSaveRequest] = []

    init(loaded: EditorDocument, savedHash: ContentHash) {
        self.loaded = loaded
        self.savedHash = savedHash
    }

    var dataSource: EditorDataSource {
        EditorDataSource(
            load: { [self] _ in loaded },
            save: { [self] request in await save(request) }
        )
    }

    func recordedRequests() -> [EditorSaveRequest] {
        requests
    }

    private func save(_ request: EditorSaveRequest) -> EditorDocument {
        requests = requests + [request]
        return EditorDocument(
            text: request.text,
            contentHash: savedHash,
            sourceInfo: request.sourceInfo
        )
    }
}

private actor SuspendedEditorSource {
    let loaded: EditorDocument
    let savedHash: ContentHash
    private var request: EditorSaveRequest?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?

    init(loaded: EditorDocument, savedHash: ContentHash) {
        self.loaded = loaded
        self.savedHash = savedHash
    }

    var dataSource: EditorDataSource {
        EditorDataSource(
            load: { [self] _ in loaded },
            save: { [self] request in await save(request) }
        )
    }

    func waitUntilSaveStarts() async {
        if request != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    private func save(_ request: EditorSaveRequest) async -> EditorDocument {
        self.request = request
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { saveContinuation = $0 }
        return EditorDocument(
            text: request.text,
            contentHash: savedHash,
            sourceInfo: request.sourceInfo
        )
    }
}

private actor SuspendedIndexRefreshFailureSource {
    let loaded: EditorDocument
    let savedHash: ContentHash
    private var request: EditorSaveRequest?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var saveContinuation: CheckedContinuation<Void, Never>?

    init(loaded: EditorDocument, savedHash: ContentHash) {
        self.loaded = loaded
        self.savedHash = savedHash
    }

    var dataSource: EditorDataSource {
        EditorDataSource(
            load: { [self] _ in loaded },
            save: { [self] request in try await save(request) }
        )
    }

    func waitUntilSaveStarts() async {
        if request != nil { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeWithIndexFailure() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    private func save(_ request: EditorSaveRequest) async throws -> EditorDocument {
        self.request = request
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { saveContinuation = $0 }
        throw EditorDataSourceError.indexRefreshFailed(
            EditorDocument(
                text: request.text,
                contentHash: savedHash,
                sourceInfo: request.sourceInfo
            )
        )
    }
}

private actor SaveRefreshRecorder {
    private var recordedPaths: [VaultPath] = []

    func record(_ path: VaultPath) {
        recordedPaths = recordedPaths + [path]
    }

    func paths() -> [VaultPath] {
        recordedPaths
    }
}

private struct LocalEditorFixture {
    let root: URL
    let path: VaultPath
    let url: URL
    let originalData: Data
    let store: LocalVaultStore

    init(data: Data) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        path = try VaultPath(decodedRelativePath: "Note.md")
        url = root.appendingPathComponent(path.description)
        originalData = data
        try data.write(to: url)
        store = try LocalVaultStore(root: root)
    }

    var source: EditorDataSource {
        .localVault(store)
    }

    func modifiedAt() throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension Data {
    fileprivate func replacing(_ original: Data, with replacement: Data) -> Data {
        guard let range = range(of: original) else { return self }
        var result = self
        result.replaceSubrange(range, with: replacement)
        return result
    }
}
