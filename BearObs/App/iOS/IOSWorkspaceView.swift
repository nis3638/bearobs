import SwiftUI

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLibrary
#endif

/// iOS workspace shell (REQ-004 §4.2/§4.3, REQ-005 FR-001): compact width
/// presents the fixed three-entry tab navigation (notes card feed / review /
/// tags), regular width reuses the shared three-column workspace so iPad keeps
/// REQ-001's column responsibilities. The reader is always constructed with
/// `editorSource == nil`; there is no write path in this target.
struct IOSWorkspaceView: View {
    @Bindable var workspace: AppWorkspaceModel
    @State private var isImporterPresented = false

    var body: some View {
        Group {
            if workspace.vaultURL == nil {
                VaultSelectionPrompt(
                    descriptionText: "BearObs 只读展示你选择的 Vault 内容，不会修改任何笔记。",
                    errorMessage: workspace.errorMessage,
                    openVault: openVault
                )
            } else {
                IOSVaultWorkspaceView(
                    environment: workspace.environment,
                    openVault: openVault
                )
                .id(workspace.environment.vaultID)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            workspace.handleVaultImport(result)
        }
        .alert(
            "无法打开 Vault",
            isPresented: Binding(
                get: { workspace.vaultURL != nil && workspace.errorMessage != nil },
                set: { isPresented in
                    if !isPresented { workspace.dismissErrorMessage() }
                }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(workspace.errorMessage ?? "")
        }
    }

    private func openVault() {
        #if DEBUG
            if workspace.openUITestVaultIfConfigured() { return }
        #endif
        isImporterPresented = true
    }
}

private struct IOSVaultWorkspaceView: View {
    let environment: AppEnvironment
    let openVault: () -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @SceneStorage("ios.workspace.vault-id") private var restoredVaultID = ""
    @SceneStorage("ios.workspace.destination") private var restoredDestinationID = "section:notes"
    @SceneStorage("ios.workspace.note-path") private var restoredNotePath = ""

    var body: some View {
        if horizontalSizeClass == .compact {
            IOSCompactWorkspaceView(environment: environment, openVault: openVault)
        } else {
            VaultWorkspaceView(
                environment: environment,
                initialDestination: initialDestination,
                initialSelectedPath: initialSelectedPath,
                destinationDidChange: persistDestination,
                selectedPathDidChange: persistSelectedPath
            )
            .toolbar { OpenVaultToolbar(openVault: openVault) }
        }
    }

    private var isRestoringCurrentVault: Bool {
        restoredVaultID == environment.vaultID?.uuidString
    }

    private var initialDestination: WorkspaceDestination {
        guard isRestoringCurrentVault else { return .section(.notes) }
        return WorkspaceDestination.restore(from: restoredDestinationID)
    }

    private var initialSelectedPath: VaultPath? {
        guard isRestoringCurrentVault, !restoredNotePath.isEmpty else { return nil }
        return try? VaultPath(decodedRelativePath: restoredNotePath)
    }

    private func persistDestination(_ destination: WorkspaceDestination?) {
        restoredVaultID = environment.vaultID?.uuidString ?? ""
        restoredDestinationID = (destination ?? .section(.notes)).restorationID
    }

    private func persistSelectedPath(_ path: VaultPath?) {
        restoredVaultID = environment.vaultID?.uuidString ?? ""
        restoredNotePath = path?.description ?? ""
    }
}

private struct OpenVaultToolbar: ToolbarContent {
    let openVault: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("打开 Vault…", systemImage: "folder", action: openVault)
                .accessibilityIdentifier("open-vault")
        }
    }
}

// MARK: - Compact width (iPhone)

/// REQ-005 FR-001.1：紧凑宽度顶级入口固定为三个——笔记（卡片流）、回顾、
/// 标签。「最近」由卡片流的时间倒序覆盖，「搜索」由卡片流顶部搜索框承接，
/// 「收藏」不再出现在紧凑宽度顶级入口。
private struct IOSCompactWorkspaceView: View {
    let environment: AppEnvironment
    let openVault: () -> Void

    var body: some View {
        TabView {
            CompactCardFeedTab(
                environment: environment,
                openVault: openVault
            )
            CompactReviewTab(environment: environment)
            CompactTagTab(
                environment: environment,
                openVault: openVault
            )
        }
        .accessibilityIdentifier("ios-tab-workspace")
    }
}

/// 笔记 tab：卡片流 + 阅读面推入。推入沿用 `navigationDestination(item:)`，
/// 返回时 item 自动清空，卡片流的过滤状态与滚动位置不受影响。
private struct CompactCardFeedTab: View {
    let environment: AppEnvironment
    let openVault: () -> Void

    @State private var selection: VaultPath?

    var body: some View {
        NavigationStack {
            CardFeedView(
                libraryModel: environment.libraryModel,
                tagsModel: environment.tagsModel,
                searchModel: environment.searchModel,
                readerSource: environment.readerSource,
                favoritesModel: environment.favoritesModel,
                selection: $selection
            )
            .toolbar { OpenVaultToolbar(openVault: openVault) }
            .navigationDestination(item: $selection) { path in
                ReaderView(
                    path: path,
                    source: environment.readerSource,
                    favorites: environment.favoritesModel,
                    editorSource: nil
                )
            }
        }
        .tabItem {
            Label("笔记", systemImage: "note.text")
                .accessibilityIdentifier("ios-tab-notes")
        }
    }
}

/// 回顾 tab：规则设置与当日批次（REQ-005 FR-002），由 T5 实现接入。
private struct CompactReviewTab: View {
    let environment: AppEnvironment

    var body: some View {
        NavigationStack {
            ReviewRootView(environment: environment)
        }
        .tabItem {
            Label("回顾", systemImage: "sparkles")
                .accessibilityIdentifier("ios-tab-review")
        }
    }
}

/// 标签 tab：标签列表在前；点标签推入预置了该过滤条件的卡片流
/// （REQ-005 FR-003.4），卡片流内点卡片继续推入阅读面。标签匹配复用
/// 完整标签身份的精确匹配语义（REQ-001 / FR-003.2），过滤可清除（FR-003.3）。
private struct CompactTagTab: View {
    let environment: AppEnvironment
    let openVault: () -> Void

    @State private var selection: VaultPath?

    var body: some View {
        NavigationStack {
            CompactTagList(
                tagsModel: environment.tagsModel,
                availabilityModel: environment.libraryModel
            )
            .toolbar { OpenVaultToolbar(openVault: openVault) }
            .navigationDestination(for: String.self) { normalizedName in
                CardFeedView(
                    libraryModel: environment.libraryModel,
                    tagsModel: environment.tagsModel,
                    searchModel: environment.searchModel,
                    readerSource: environment.readerSource,
                    favoritesModel: environment.favoritesModel,
                    selection: $selection,
                    presetTagIdentity: normalizedName
                )
                .navigationDestination(item: $selection) { path in
                    ReaderView(
                        path: path,
                        source: environment.readerSource,
                        favorites: environment.favoritesModel,
                        editorSource: nil
                    )
                }
            }
        }
        .tabItem {
            Label("标签", systemImage: "number")
                .accessibilityIdentifier("ios-tab-tags")
        }
    }
}

struct CompactTagList: View {
    let tagsModel: TagsFeatureModel
    let availabilityModel: LibraryFeatureModel?

    init(
        tagsModel: TagsFeatureModel,
        availabilityModel: LibraryFeatureModel? = nil
    ) {
        self.tagsModel = tagsModel
        self.availabilityModel = availabilityModel
    }

    var body: some View {
        content
            .navigationTitle("标签")
            .task { await tagsModel.loadIfNeeded() }
            .task { await availabilityModel?.load() }
            .refreshable { await refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch tagsModel.state {
        case .loading:
            ProgressView("正在加载标签")
                .accessibilityIdentifier("workspace-tags-loading")
        case .empty:
            if availability.unavailableCount > 0 {
                LibraryUnavailableSourcesView(
                    count: availability.unavailableCount,
                    retry: { Task { await refresh() } }
                )
            } else {
                ContentUnavailableView(
                    "还没有标签",
                    systemImage: "number",
                    description: Text("笔记中的 Frontmatter 标签和正文 Inline Tag 会出现在这里。")
                )
                .accessibilityIdentifier("workspace-tags-empty")
            }
        case .content(let tags):
            tagList(tags)
        case .failure(let tags):
            if tags.isEmpty {
                ContentUnavailableView {
                    Label("无法加载标签", systemImage: "exclamationmark.triangle")
                } actions: {
                    Button("重试") {
                        Task { await tagsModel.load() }
                    }
                }
                .accessibilityIdentifier("workspace-tags-error")
            } else {
                tagList(
                    tags,
                    warning: TagListPresentation.staleWarning
                )
            }
        }
    }

    @ViewBuilder
    private func tagList(
        _ tags: [IndexedTagSummary],
        warning: String? = nil
    ) -> some View {
        List {
            if availability.unavailableCount > 0 {
                LibraryUnavailableSourcesRow(count: availability.unavailableCount)
            }
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace-tags-stale-warning")
            }
            ForEach(CompactTagRow.flatten(TagNavigationTree.build(from: tags))) { row in
                CompactTagRowView(row: row)
            }
        }
        .listStyle(.plain)
        .accessibilityIdentifier("workspace-tags-list")
    }

    private var availability: IndexAvailabilityState {
        availabilityModel?.availability
            ?? IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
    }

    private func refresh() async {
        await availabilityModel?.refresh()
        await tagsModel.load()
    }
}

/// The tag tree is flattened as data, not recursively type-erased as Views.
/// Depth remains explicit, so hierarchy survives without `AnyView` and `List`
/// supplies correct scrolling, Dynamic Type sizing and row virtualization.
private struct CompactTagRow: Identifiable {
    let node: TagNavigationNode
    let depth: Int

    var id: String { node.id }

    static func flatten(
        _ nodes: [TagNavigationNode],
        depth: Int = 0
    ) -> [CompactTagRow] {
        nodes.flatMap { node in
            [CompactTagRow(node: node, depth: depth)]
                + flatten(node.children, depth: depth + 1)
        }
    }
}

private struct CompactTagRowView: View {
    let row: CompactTagRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if let summary = row.node.summary {
                NavigationLink(value: summary.normalizedName) {
                    tagLabel(summary)
                }
                .accessibilityIdentifier("workspace-tag-\(summary.normalizedName)")
                .accessibilityLabel(
                    TagListPresentation.accessibilityLabel(
                        name: row.node.displayPath,
                        noteCount: summary.noteCount
                    )
                )
            } else {
                Label(row.node.displayName, systemImage: "folder")
                    .accessibilityLabel("\(row.node.displayPath)，分组")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }

    @ViewBuilder
    private func tagLabel(_ summary: IndexedTagSummary) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    tagIcon
                    Text(row.node.displayName)
                        .lineLimit(nil)
                }
                Text("\(summary.noteCount) 篇")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                tagIcon
                Text(row.node.displayName)
                    .lineLimit(nil)
                Spacer(minLength: 4)
                Text("\(summary.noteCount) 篇")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var tagIcon: some View {
        Image(systemName: "number")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}
