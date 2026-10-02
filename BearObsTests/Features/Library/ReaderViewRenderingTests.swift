import SwiftUI
import XCTest

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsMarkdown
    @testable import BearObsLibrary
#else
    @testable import BearObs
#endif

@MainActor
final class ReaderViewRenderingTests: XCTestCase {
    func testEveryReaderBlockRendersWithoutExecutingUnsafeContent() {
        let safeURL = URL(string: "https://example.com")
        let styled: [MarkdownRenderInline] = [
            .text("Plain "),
            .emphasis([.text("emphasis")]),
            .strong([.text(" strong")]),
            .strikethrough([.text(" removed")]),
            .code(" code"),
            .link(content: [.text(" link")], destination: safeURL),
            .link(content: [.text(" blocked")], destination: nil),
            .image(alternativeText: "diagram"),
            .lineBreak,
            .image(alternativeText: ""),
            .wikiLink(
                label: "Internal",
                target: "Folder/Note",
                resolution: .resolved(try! VaultPath(decodedRelativePath: "Folder/Note.md"))
            ),
            .wikiLink(label: "Missing", target: "Missing", resolution: .missing),
            .wikiLink(label: "Twin", target: "Twin", resolution: .ambiguous),
        ]
        let items = [
            MarkdownRenderListItem(task: .checked, blocks: [.paragraph([.text("Done")])]),
            MarkdownRenderListItem(task: .unchecked, blocks: [.paragraph([.text("Open")])]),
            MarkdownRenderListItem(task: nil, blocks: [.paragraph([.text("Item")])]),
        ]
        let blocks: [MarkdownRenderBlock] = [
            .heading(level: 1, content: styled),
            .heading(level: 2, content: [.text("Second")]),
            .heading(level: 3, content: [.text("Third")]),
            .heading(level: 5, content: [.text("Minor")]),
            .paragraph(styled),
            .quote([.paragraph([.text("Quote")])]),
            .unorderedList(items),
            .orderedList(start: 4, items: items),
            .codeBlock(language: "swift", code: "let value = 1"),
            .codeBlock(language: nil, code: "plain"),
            .thematicBreak,
            .fallback("<script>shown as text</script>"),
        ]
        let renderer = ImageRenderer(
            content: ScrollView {
                ReaderBlocksView(blocks: blocks)
                    .frame(width: 640, alignment: .leading)
                    .padding()
            }
        )

        XCTAssertNotNil(renderer.cgImage)
    }

    func testReaderDocumentBlocksRenderTopLevelEntriesWithAnchors() throws {
        let source = "# 标题\n\n正文段落，验证锚点视图渲染。\n\n- 列表项\n"
        let note = try MarkdownNoteParser.parse(
            Data(source.utf8),
            at: try VaultPath(decodedRelativePath: "Anchors.md")
        )
        let document = MarkdownReaderRenderer.render(note)
        XCTAssertEqual(document.entries.count, 3)

        let renderer = ImageRenderer(
            content: ScrollView {
                ReaderDocumentBlocksView(entries: document.entries)
                    .frame(width: 640, alignment: .leading)
                    .padding()
            }
        )

        XCTAssertNotNil(renderer.cgImage)
    }

    func testInternalRouteRoundTripsCanonicalPathAndRejectsForgedURLs() throws {
        let path = try VaultPath(decodedRelativePath: "空 格/100% Note.md")
        let url = ReaderInternalRoute.url(for: path)

        XCTAssertEqual(ReaderInternalRoute.path(from: url), path)
        for forged in [
            URL(string: "https://note.invalid?path=Secret.md")!,
            URL(string: "bearobs://other?path=Secret.md")!,
            URL(string: "bearobs://note?path=../Secret.md")!,
            URL(string: "bearobs://user:pass@note?path=Secret.md")!,
            URL(string: "bearobs://note?path=Secret.md&extra=1")!,
        ] {
            XCTAssertNil(ReaderInternalRoute.path(from: forged), forged.absoluteString)
        }
    }

    func testFavoritesAndRecentViewsRenderTheirNavigationClosure() async throws {
        let path = try VaultPath(decodedRelativePath: "Recent.md")
        let note = IndexedNoteSummary(
            path: path,
            title: "Recent",
            preview: "Preview",
            modifiedAt: .distantPast,
            parseStatus: .complete
        )
        let hit = IndexSearchHit(
            path: path,
            title: note.title,
            preview: note.preview,
            parseStatus: note.parseStatus,
            modifiedAt: note.modifiedAt
        )
        let favorites = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [path] },
                setFavorite: { _, _ in [path] }
            )
        )
        let recent = SearchFeatureModel(source: SearchDataSource { _ in [hit] })
        await favorites.load()
        await recent.search("")

        let favoritesRenderer = ImageRenderer(
            content: NavigationStack {
                FavoritesView(
                    model: favorites,
                    readerSource: .unavailable
                )
            }
            .frame(width: 390, height: 700)
        )
        let recentRenderer = ImageRenderer(
            content: NavigationStack {
                RecentView(
                    model: recent,
                    readerSource: .unavailable,
                    favorites: favorites
                )
            }
            .frame(width: 390, height: 700)
        )

        XCTAssertNotNil(favoritesRenderer.cgImage)
        XCTAssertNotNil(recentRenderer.cgImage)
    }

    func testLibraryEntriesAndReaderFavoriteToolbarRenderWithSharedState() async throws {
        let path = try VaultPath(decodedRelativePath: "Shared.md")
        let note = makeNote(path: path)
        let hit = makeHit(from: note)
        let favorites = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [path] },
                setFavorite: { _, _ in [path] }
            )
        )
        let library = LibraryFeatureModel(
            source: LibraryDataSource(load: { [note] }, refresh: {})
        )
        let recent = SearchFeatureModel(source: SearchDataSource { _ in [hit] })
        await favorites.load()
        await library.load()
        await recent.search("")
        let document = MarkdownRenderDocument(
            title: "Shared",
            blocks: [.paragraph([.text("Body")])]
        )
        let reader = ReaderFeatureModel(
            path: path,
            source: ReaderDataSource { _ in document },
            initialState: .content(document),
            favorites: favorites
        )

        let libraryRenderer = ImageRenderer(
            content: LibraryView(
                model: library,
                readerSource: .unavailable,
                favoritesModel: favorites,
                recentModel: recent
            )
            .frame(width: 390, height: 700)
        )
        let readerRenderer = ImageRenderer(
            content: NavigationStack {
                ReaderView(model: reader)
            }
            .frame(width: 390, height: 700)
        )

        XCTAssertNotNil(libraryRenderer.cgImage)
        XCTAssertNotNil(readerRenderer.cgImage)
    }

    func testFavoritesAndRecentBoundaryStatesRender() async throws {
        let path = try VaultPath(decodedRelativePath: "Stable.md")
        let note = makeNote(path: path)
        let loadingFavorites = FavoritesFeatureModel(source: .empty)
        let emptyFavorites = FavoritesFeatureModel(source: .empty)
        let failedFavorites = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { throw RenderFailure.expected },
                loadFavoritePaths: { [] },
                setFavorite: { _, _ in [] }
            )
        )
        let updateFailedFavorites = FavoritesFeatureModel(
            source: FavoriteDataSource(
                loadNotes: { [note] },
                loadFavoritePaths: { [path] },
                setFavorite: { _, _ in throw RenderFailure.expected }
            )
        )
        await emptyFavorites.load()
        await failedFavorites.load()
        await updateFailedFavorites.load()
        await updateFailedFavorites.setFavorite(path, isFavorite: false)

        let loadingRecent = SearchFeatureModel(source: .empty)
        let emptyRecent = SearchFeatureModel(source: .empty)
        let failedRecent = SearchFeatureModel(
            source: SearchDataSource { _ in throw RenderFailure.expected }
        )
        await emptyRecent.search("")
        await failedRecent.search("")

        let views: [AnyView] = [
            AnyView(FavoritesView(model: loadingFavorites)),
            AnyView(FavoritesView(model: emptyFavorites)),
            AnyView(FavoritesView(model: failedFavorites)),
            AnyView(FavoritesView(model: updateFailedFavorites)),
            AnyView(RecentView(model: loadingRecent)),
            AnyView(RecentView(model: emptyRecent)),
            AnyView(RecentView(model: failedRecent)),
        ]

        for view in views {
            let renderer = ImageRenderer(
                content: NavigationStack { view }
                    .frame(width: 390, height: 700)
            )
            XCTAssertNotNil(renderer.cgImage)
        }
    }

    func testAccessibilityCopyDescribesMeaningWithoutRelyingOnColorOrIcon() {
        XCTAssertEqual(
            LibraryAvailabilityPresentation.title(count: 2),
            "有 2 个源文件暂不可用"
        )
        XCTAssertFalse(LibraryAvailabilityPresentation.message.contains("/"))
        XCTAssertEqual(LibraryAvailabilityPresentation.retryTitle, "重试")
        XCTAssertEqual(
            LibraryAccessibilityText.favoriteButtonLabel(
                isReady: false,
                isFavorite: false
            ),
            "正在读取收藏状态"
        )
        XCTAssertEqual(
            LibraryAccessibilityText.favoriteButtonLabel(
                isReady: true,
                isFavorite: false,
                isUpdating: true
            ),
            "正在更新收藏状态"
        )
        XCTAssertEqual(
            LibraryAccessibilityText.favoriteButtonLabel(
                isReady: true,
                isFavorite: false
            ),
            "收藏"
        )
        XCTAssertEqual(
            LibraryAccessibilityText.favoriteButtonHint(isFavorite: false),
            "将这篇笔记添加到收藏"
        )
        XCTAssertEqual(
            LibraryAccessibilityText.favoriteButtonLabel(
                isReady: true,
                isFavorite: true
            ),
            "取消收藏"
        )
        XCTAssertEqual(
            LibraryAccessibilityText.favoriteButtonHint(isFavorite: true),
            "将这篇笔记从收藏中移除"
        )
        XCTAssertEqual(
            LibraryAccessibilityText.tagLabel(name: "项目", noteCount: 3),
            "项目，3 篇笔记"
        )
    }

    func testReaderAccessibilitySegmentsExposeLinkDestinations() throws {
        let internalPath = try VaultPath(decodedRelativePath: "目标笔记.md")
        let externalURL = URL(string: "https://example.com")!
        let inline: [MarkdownRenderInline] = [
            .text("前缀 "),
            .link(content: [.text("外部链接")], destination: externalURL),
            .text(" 和 "),
            .wikiLink(
                label: "内部链接",
                target: "目标笔记",
                resolution: .resolved(internalPath)
            ),
        ]

        let segments = ReaderAttributedText.accessibilitySegments(inline)

        XCTAssertEqual(segments.map(\.label), ["前缀 ", "外部链接", " 和 ", "内部链接"])
        XCTAssertNil(segments[0].destination)
        XCTAssertEqual(segments[1].destination, externalURL)
        XCTAssertEqual(segments[3].destination, ReaderInternalRoute.url(for: internalPath))
    }

    func testPrimaryContentRendersAtLargestAccessibilitySizeInBothColorSchemes() throws {
        let path = try VaultPath(decodedRelativePath: "很长的辅助功能字号验证标题.md")
        let note = IndexedNoteSummary(
            path: path,
            title: "很长的辅助功能字号验证标题",
            preview: "摘要在大字体下仍保留可读的布局，并允许系统语义颜色适配外观。",
            modifiedAt: .distantPast,
            parseStatus: .degraded
        )
        let hit = makeHit(from: note)
        let blocks: [MarkdownRenderBlock] = [
            .heading(level: 1, content: [.text("可访问的 Reader 标题")]),
            .quote([.paragraph([.text("引用内容")])]),
            .unorderedList([
                MarkdownRenderListItem(
                    task: .checked,
                    blocks: [.paragraph([.text("已完成任务")])]
                )
            ]),
            .codeBlock(language: "swift", code: "let accessible = true"),
        ]

        for colorScheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(
                content: ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LibraryNoteRow(note: note)
                        SearchResultRow(hit: hit)
                        ReaderBlocksView(blocks: blocks)
                    }
                    .padding()
                }
                .frame(width: 390, height: 844)
                .environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.colorScheme, colorScheme)
            )

            XCTAssertNotNil(renderer.cgImage, "Failed in \(colorScheme) mode")
        }
    }

    func testTagListRendersAtLargestAccessibilitySizeInBothColorSchemes() async {
        let tag = IndexedTagSummary(
            normalizedName: "accessibility",
            displayName: "很长的辅助功能标签名称",
            noteCount: 12_345
        )
        let model = TagsFeatureModel(
            source: TagLibraryDataSource(
                loadTags: { [tag] },
                loadNotes: { _ in [] }
            )
        )
        await model.load()

        for colorScheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(
                content: TagsView(model: model)
                    .frame(width: 390, height: 844)
                    .environment(\.dynamicTypeSize, .accessibility5)
                    .environment(\.colorScheme, colorScheme)
            )

            XCTAssertNotNil(renderer.cgImage, "Failed in \(colorScheme) mode")
        }
    }

    #if os(iOS)
        /// 自动化只证明 AX5 下可生成布局；M-IOS-5.9 的浅/深色人工走查仍是明确待办。
        func testCompactTagListRendersAtLargestAccessibilitySizeInBothColorSchemes() async {
            let tag = IndexedTagSummary(
                normalizedName: "project/mobile",
                displayName: "Project/很长的移动端辅助功能标签名称",
                noteCount: 12_345
            )
            let model = TagsFeatureModel(
                source: TagLibraryDataSource(
                    loadTags: { [tag] },
                    loadNotes: { _ in [] }
                )
            )
            await model.load()

            for colorScheme in [ColorScheme.light, .dark] {
                let renderer = ImageRenderer(
                    content: NavigationStack {
                        CompactTagList(tagsModel: model)
                    }
                    .frame(width: 390, height: 844)
                    .environment(\.dynamicTypeSize, .accessibility5)
                    .environment(\.colorScheme, colorScheme)
                )

                XCTAssertNotNil(renderer.cgImage, "Failed in \(colorScheme) mode")
            }
        }
    #endif
}

extension ReaderViewRenderingTests {
    private enum RenderFailure: Error {
        case expected
    }

    private func makeNote(path: VaultPath) -> IndexedNoteSummary {
        IndexedNoteSummary(
            path: path,
            title: path.fileNameWithoutExtension,
            preview: "Preview",
            modifiedAt: .distantPast,
            parseStatus: .complete
        )
    }

    private func makeHit(from note: IndexedNoteSummary) -> IndexSearchHit {
        IndexSearchHit(
            path: note.path,
            title: note.title,
            preview: note.preview,
            parseStatus: note.parseStatus,
            modifiedAt: note.modifiedAt
        )
    }
}
