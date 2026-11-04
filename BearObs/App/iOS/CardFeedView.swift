import SwiftUI

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLibrary
#endif

/// REQ-005 FR-001/FR-003/FR-004：iPhone 紧凑宽度的卡片流。
/// 顶部搜索框复用现有离线全文搜索；标签过滤条可清除；主体是按修改时间
/// 倒序的 `Card` 列表。数据库读取不在这里发生：笔记来自 `LibraryFeatureModel`
/// 的既有状态，标签来自 `TagsFeatureModel` 的既有标签查询（完整标签身份，
/// 精确匹配语义与 REQ-001 一致）。索引中/空/失败状态复用现有文案与互斥状态。
struct CardFeedView: View {
    let libraryModel: LibraryFeatureModel
    let tagsModel: TagsFeatureModel
    let searchModel: SearchFeatureModel
    let readerSource: ReaderDataSource
    let favoritesModel: FavoritesFeatureModel
    /// FR-003.4：由标签入口推入时预置的完整标签身份；nil 表示常规卡片流。
    let presetTagIdentity: String?
    @Binding var selection: VaultPath?

    @State private var query = ""
    @State private var activeTagIdentity: String?
    @State private var tagsByPath: [VaultPath: [String]] = [:]
    @State private var indexedTagIdentities: Set<String> = []

    init(
        libraryModel: LibraryFeatureModel,
        tagsModel: TagsFeatureModel,
        searchModel: SearchFeatureModel,
        readerSource: ReaderDataSource,
        favoritesModel: FavoritesFeatureModel,
        selection: Binding<VaultPath?>,
        presetTagIdentity: String? = nil
    ) {
        self.libraryModel = libraryModel
        self.tagsModel = tagsModel
        self.searchModel = searchModel
        self.readerSource = readerSource
        self.favoritesModel = favoritesModel
        self.presetTagIdentity = presetTagIdentity
        _selection = selection
        _activeTagIdentity = State(initialValue: presetTagIdentity)
    }

    var body: some View {
        content
            .navigationTitle(navigationTitle)
            .searchable(text: $query, prompt: "标题、正文或标签")
            .task { await loadFeed() }
            .task(id: query) {
                guard !query.isEmpty else { return }
                await searchModel.search(query)
            }
            .refreshable { await refreshFeed() }
    }

    /// 常规卡片流标题「笔记」；标签入口推入的预置过滤卡片流以标签名命名。
    private var navigationTitle: String {
        guard let presetTagIdentity else { return "笔记" }
        return filterDisplayName(for: presetTagIdentity)
    }

    @ViewBuilder
    private var content: some View {
        if query.isEmpty {
            libraryContent
        } else {
            searchContent
        }
    }

    // MARK: - 卡片流（时间倒序）

    @ViewBuilder
    private var libraryContent: some View {
        switch libraryModel.state {
        case .loading:
            ProgressView("正在加载笔记")
        case .indexing(let notes):
            feedList(visibleCards(for: notes), status: .indexing)
        case .content(let notes):
            feedList(visibleCards(for: notes), status: nil)
        case .empty:
            if libraryModel.availability.unavailableCount > 0 {
                LibraryUnavailableSourcesView(
                    count: libraryModel.availability.unavailableCount,
                    retry: { Task { await refreshFeed() } }
                )
            } else {
                ContentUnavailableView(
                    "还没有笔记",
                    systemImage: "doc.text",
                    description: Text("这个 Vault 中还没有可读取的 Markdown 笔记。")
                )
                .accessibilityIdentifier("card-feed-empty")
            }
        case .failure(let failure, let notes):
            if notes.isEmpty {
                WorkspaceFailureView(
                    title: failure == .loadFailed ? "无法加载笔记" : "索引更新失败",
                    message: "请重试；如果问题持续，可在设置中重建索引。",
                    retry: { Task { await libraryModel.load() } }
                )
            } else {
                feedList(
                    visibleCards(for: notes),
                    status: .failure(
                        title: failure == .loadFailed ? "无法加载笔记" : "索引更新失败",
                        message: "现有笔记仍可阅读。请稍后重试更新。"
                    )
                )
            }
        }
    }

    // MARK: - 搜索结果（仍以卡片呈现）

    @ViewBuilder
    private var searchContent: some View {
        switch searchModel.state {
        case .loading:
            ProgressView("正在搜索")
        case .content(let hits):
            let matched = visibleCards(for: libraryModel.state.visibleNotes)
            let filtered = CardFeedModel.filtering(matched, bySearch: Set(hits.map(\.path)))
            if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
                    .accessibilityIdentifier("workspace-search-no-results")
            } else {
                feedList(filtered, status: nil)
            }
        case .empty:
            ContentUnavailableView.search(text: query)
                .accessibilityIdentifier("workspace-search-no-results")
        case .failure:
            WorkspaceFailureView(
                title: "无法搜索",
                message: "请修改查询或稍后重试。",
                retry: { Task { await searchModel.search(query) } }
            )
        }
    }

    private func feedList(
        _ cards: [Card],
        status: WorkspaceNoteListStatus?
    ) -> some View {
        List {
            if libraryModel.availability.unavailableCount > 0 {
                Section {
                    LibraryUnavailableSourcesRow(
                        count: libraryModel.availability.unavailableCount
                    )
                }
            }
            if let status {
                Section {
                    WorkspaceNoteListStatusRow(status: status) {
                        Task { await libraryModel.refresh() }
                    }
                }
            }
            if let activeTagIdentity {
                Section {
                    filterBar(identity: activeTagIdentity)
                }
            }
            Section {
                ForEach(cards) { card in
                    CardRow(
                        card: card,
                        onOpen: { selection = card.path },
                        onTagSelect: { identity in
                            activeTagIdentity = identity
                        }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("card-feed-list")
    }

    /// FR-003.3：可清除的标签过滤条。
    private func filterBar(identity: String) -> some View {
        HStack(spacing: 8) {
            Label(filterDisplayName(for: identity), systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("card-feed-filter-bar")
            Spacer(minLength: 8)
            Button("清除") {
                activeTagIdentity = nil
            }
            .buttonStyle(.borderless)
            .font(.subheadline)
            .accessibilityIdentifier("card-feed-filter-clear")
        }
    }

    // MARK: - 数据装配

    /// 投影为卡片（完整标签身份按索引顺序），再按当前标签过滤精确收敛。
    private func visibleCards(for notes: [IndexedNoteSummary]) -> [Card] {
        let cards = notes.map { note in
            CardFeedModel.card(from: note, tags: tagsByPath[note.path] ?? [])
        }
        guard let activeTagIdentity else { return cards }
        return CardFeedModel.filtering(
            cards,
            byTag: activeTagIdentity,
            tagsByPath: tagsByPath
        )
    }

    private func filterDisplayName(for identity: String) -> String {
        tagsModel.state.visibleTags.first { $0.normalizedName == identity }?.displayName
            ?? identity
    }

    private func loadFeed() async {
        await libraryModel.load()
        await tagsModel.loadIfNeeded()
        await rebuildTagIndexIfNeeded()
    }

    private func refreshFeed() async {
        await libraryModel.refresh()
        await tagsModel.load()
        await rebuildTagIndex()
    }

    /// 返回卡片流时标签集合未变化则复用既有映射，避免每次推入阅读面都重查。
    private func rebuildTagIndexIfNeeded() async {
        let identities = Set(tagsModel.state.visibleTags.map(\.normalizedName))
        guard tagsByPath.isEmpty || identities != indexedTagIdentities else { return }
        await rebuildTagIndex()
    }

    /// 卡片标签来自既有标签查询：先取全部标签，再按标签取笔记并反转为
    /// 「路径 → 完整标签身份」。不新增索引列，也不改动索引 schema。
    private func rebuildTagIndex() async {
        let tags = tagsModel.state.visibleTags
        var map: [VaultPath: [String]] = [:]
        for tag in tags {
            let taggedModel = tagsModel.notesModel(for: tag)
            await taggedModel.load()
            guard case .content(let notes) = taggedModel.state else { continue }
            for note in notes {
                map[note.path, default: []].append(tag.normalizedName)
            }
        }
        tagsByPath = map
        indexedTagIdentities = Set(tags.map(\.normalizedName))
    }
}

/// 一张卡片：标题（无标题回退文件名，由投影保证）、相对日期、摘要、
/// 标签碎片。点卡片本体推入阅读面；点标签碎片设置过滤，不推入阅读。
private struct CardRow: View {
    let card: Card
    let onOpen: () -> Void
    let onTagSelect: (String) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.title)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    Spacer(minLength: 8)
                    Text("修改于 \(card.modifiedAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !card.excerpt.isEmpty {
                    Text(card.excerpt)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                }
                if !card.visibleTags.isEmpty || card.extraTagCount > 0 {
                    tagChips
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("card-row-\(card.path.description)")
    }

    private var tagChips: some View {
        HStack(spacing: 6) {
            ForEach(card.visibleTags, id: \.self) { identity in
                Button {
                    onTagSelect(identity)
                } label: {
                    Text("#\(identity)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("card-tag-\(identity)")
            }
            if card.extraTagCount > 0 {
                Text("+\(card.extraTagCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("card-extra-tags")
            }
        }
    }
}
