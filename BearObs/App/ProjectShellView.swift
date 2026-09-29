import Observation
import SwiftUI
import UniformTypeIdentifiers

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLibrary
#endif

struct ProjectShellView: View {
    @Bindable private var workspace: AppWorkspaceModel
    @State private var isImporterPresented = false

    init(workspace: AppWorkspaceModel) {
        _workspace = Bindable(workspace)
    }

    var body: some View {
        Group {
            if workspace.vaultURL == nil {
                VaultSelectionPrompt(
                    errorMessage: workspace.errorMessage,
                    openVault: { isImporterPresented = true }
                )
            } else {
                VaultWorkspaceView(environment: workspace.environment)
                    .id(workspace.environment.vaultID)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("打开 Vault…", systemImage: "folder") {
                    isImporterPresented = true
                }
                .accessibilityIdentifier("open-vault")
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            workspace.openVault(url)
        }
    }
}

enum WorkspaceSection: String, CaseIterable, Hashable, Identifiable {
    case notes
    case recent
    case favorites
    case search

    var id: Self { self }

    var title: String {
        switch self {
        case .notes: "笔记"
        case .recent: "最近"
        case .favorites: "收藏"
        case .search: "搜索"
        }
    }

    var systemImage: String {
        switch self {
        case .notes: "note.text"
        case .recent: "clock"
        case .favorites: "star"
        case .search: "magnifyingglass"
        }
    }
}

enum WorkspaceDestination: Hashable, Identifiable {
    case section(WorkspaceSection)
    case tag(String)

    var id: String {
        switch self {
        case .section(let section): "section:\(section.rawValue)"
        case .tag(let normalizedName): "tag:\(normalizedName)"
        }
    }

    var tagIdentity: String? {
        guard case .tag(let normalizedName) = self else { return nil }
        return normalizedName
    }
}

enum WorkspaceSelectionPolicy {
    enum Transition: Equatable {
        case select(VaultPath?)
        case requiresDiscardConfirmation(VaultPath?)
    }

    static func transition(
        from current: VaultPath?,
        to next: VaultPath?,
        hasUnsavedChanges: Bool
    ) -> Transition {
        guard current != next, hasUnsavedChanges else { return .select(next) }
        return .requiresDiscardConfirmation(next)
    }

    static func retainedPath(
        _ selectedPath: VaultPath?,
        in notes: [IndexedNoteSummary]
    ) -> VaultPath? {
        guard let selectedPath else { return nil }
        return notes.contains { $0.path == selectedPath } ? selectedPath : nil
    }

    static func retainedPath(
        _ selectedPath: VaultPath?,
        in paths: [VaultPath]
    ) -> VaultPath? {
        guard let selectedPath else { return nil }
        return paths.contains(selectedPath) ? selectedPath : nil
    }

    static func reconciledDestination(
        _ destination: WorkspaceDestination?,
        availableTags: [IndexedTagSummary],
        selectedTag: IndexedTagSummary?,
        selectedNotesState: TaggedNotesViewState
    ) -> WorkspaceDestination? {
        guard case .tag(let requestedIdentity) = destination else {
            return destination
        }

        guard
            availableTags.contains(where: {
                $0.normalizedName == requestedIdentity
            })
        else {
            return .section(.notes)
        }

        guard let selectedTag else {
            return selectedNotesState == .loading
                ? destination
                : .section(.notes)
        }

        guard selectedTag.normalizedName != requestedIdentity else {
            return destination
        }

        guard selectedNotesState != .loading else {
            return destination
        }

        guard
            availableTags.contains(where: {
                $0.normalizedName == selectedTag.normalizedName
            })
        else {
            return .section(.notes)
        }
        return .tag(selectedTag.normalizedName)
    }
}

enum WorkspaceLayout {
    static let emptyDetailTitle = "选择一篇笔记"
    static let emptyDetailMessage = "从中间列表选择笔记后，会在这里打开阅读。"
}

private struct VaultWorkspaceView: View {
    let environment: AppEnvironment
    @State private var destination: WorkspaceDestination? = .section(.notes)
    @State private var selectedPath: VaultPath?
    @State private var pendingPath: VaultPath?
    @State private var hasUnsavedEditorChanges = false
    @State private var isDiscardConfirmationPresented = false

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(
                tagsModel: environment.tagsModel,
                destination: $destination
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            collectionColumn
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 500)
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        .confirmationDialog(
            "放弃未保存的修改？",
            isPresented: $isDiscardConfirmationPresented
        ) {
            Button("放弃修改", role: .destructive) {
                selectedPath = pendingPath
                pendingPath = nil
                hasUnsavedEditorChanges = false
            }
            Button("继续编辑", role: .cancel) { pendingPath = nil }
        } message: {
            Text("切换笔记会丢弃当前详情栏中的本地草稿。")
        }
        .onChange(of: selectablePaths) { _, paths in
            guard let paths else { return }
            requestSelection(
                WorkspaceSelectionPolicy.retainedPath(
                    selectedPath,
                    in: paths
                )
            )
        }
        .onChange(of: destination) { _, nextDestination in
            guard case .section = nextDestination else { return }
            environment.tagsModel.clearTagSelection()
        }
        .onChange(of: environment.tagsModel.state) { _, _ in
            reconcileTagDestination()
        }
        .onChange(of: environment.tagsModel.selectedTag?.normalizedName) { _, _ in
            reconcileTagDestination()
        }
        .onChange(of: environment.tagsModel.selectedNotesState) { _, _ in
            reconcileTagDestination()
        }
    }

    @ViewBuilder
    private var collectionColumn: some View {
        switch destination ?? .section(.notes) {
        case .section(.notes):
            WorkspaceLibraryColumn(
                model: environment.libraryModel,
                selection: selectionBinding
            )
        case .section(.recent):
            WorkspaceRecentColumn(
                model: environment.recentModel,
                selection: selectionBinding
            )
        case .section(.favorites):
            WorkspaceFavoritesColumn(
                model: environment.favoritesModel,
                selection: selectionBinding
            )
        case .section(.search):
            WorkspaceSearchColumn(
                model: environment.searchModel,
                selection: selectionBinding
            )
        case .tag(let normalizedName):
            WorkspaceTaggedNotesColumn(
                model: environment.tagsModel,
                normalizedName: normalizedName,
                selection: selectionBinding
            )
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let selectedPath {
            ReaderView(
                path: selectedPath,
                source: environment.readerSource,
                favorites: environment.favoritesModel,
                editorSource: environment.editorSource,
                onUnsavedChangesChanged: { hasUnsavedEditorChanges = $0 }
            )
            .id(selectedPath)
        } else {
            ContentUnavailableView(
                WorkspaceLayout.emptyDetailTitle,
                systemImage: "doc.text.magnifyingglass",
                description: Text(WorkspaceLayout.emptyDetailMessage)
            )
            .accessibilityIdentifier("workspace-empty-detail")
        }
    }

    private var selectablePaths: [VaultPath]? {
        switch destination ?? .section(.notes) {
        case .section(.notes):
            return libraryPaths(environment.libraryModel.state)
        case .section(.recent):
            return searchPaths(environment.recentModel.state)
        case .section(.favorites):
            return favoritePaths(environment.favoritesModel.state)
        case .section(.search):
            return searchPaths(environment.searchModel.state)
        case .tag(let normalizedName):
            guard environment.tagsModel.selectedTag?.normalizedName == normalizedName
            else { return nil }
            return taggedPaths(environment.tagsModel.selectedNotesState)
        }
    }

    private func libraryPaths(_ state: LibraryViewState) -> [VaultPath]? {
        switch state {
        case .loading:
            nil
        case .indexing(let notes), .content(let notes), .failure(_, let notes):
            notes.map(\.path)
        case .empty:
            []
        }
    }

    private func favoritePaths(_ state: FavoritesViewState) -> [VaultPath]? {
        switch state {
        case .loading:
            nil
        case .content(let notes), .failure(_, let notes):
            notes.map(\.path)
        case .empty:
            []
        }
    }

    private func searchPaths(_ state: SearchViewState) -> [VaultPath]? {
        switch state {
        case .loading:
            nil
        case .content(let hits):
            hits.map(\.path)
        case .empty, .failure:
            []
        }
    }

    private func taggedPaths(_ state: TaggedNotesViewState) -> [VaultPath]? {
        switch state {
        case .loading:
            nil
        case .content(let notes):
            notes.map(\.path)
        case .empty, .failure:
            []
        }
    }

    private func reconcileTagDestination() {
        let nextDestination = WorkspaceSelectionPolicy.reconciledDestination(
            destination,
            availableTags: environment.tagsModel.state.visibleTags,
            selectedTag: environment.tagsModel.selectedTag,
            selectedNotesState: environment.tagsModel.selectedNotesState
        )
        guard nextDestination != destination else { return }

        let shouldClearDetail =
            destination?.tagIdentity != nil && nextDestination?.tagIdentity == nil
        destination = nextDestination
        if shouldClearDetail {
            requestSelection(nil)
            environment.tagsModel.clearTagSelection()
        }
    }

    private var selectionBinding: Binding<VaultPath?> {
        Binding(
            get: { selectedPath },
            set: { path in requestSelection(path) }
        )
    }

    private func requestSelection(_ path: VaultPath?) {
        switch WorkspaceSelectionPolicy.transition(
            from: selectedPath,
            to: path,
            hasUnsavedChanges: hasUnsavedEditorChanges
        ) {
        case .select(let path):
            selectedPath = path
        case .requiresDiscardConfirmation(let path):
            pendingPath = path
            isDiscardConfirmationPresented = true
        }
    }
}

private struct WorkspaceSidebar: View {
    let tagsModel: TagsFeatureModel
    @Binding var destination: WorkspaceDestination?
    @State private var isTagsExpanded = true
    @State private var collapsedTagPaths: Set<String> = []

    var body: some View {
        List(selection: $destination) {
            Section("资料库") {
                ForEach(WorkspaceSection.allCases) { section in
                    WorkspaceSectionRow(
                        section: section,
                        destination: $destination
                    )
                }
            }
            Section {
                DisclosureGroup(isExpanded: $isTagsExpanded) {
                    tagContent
                } label: {
                    Label("标签", systemImage: "number")
                }
                .accessibilityIdentifier("workspace-tags-group")
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("BearObs")
        .accessibilityIdentifier("workspace-sidebar")
        .task { await tagsModel.loadIfNeeded() }
        .refreshable { await tagsModel.load() }
    }

    @ViewBuilder
    private var tagContent: some View {
        switch tagsModel.state {
        case .loading:
            ProgressView("正在加载标签")
                .accessibilityIdentifier("workspace-tags-loading")
        case .empty:
            Text("还没有标签")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("workspace-tags-empty")
        case .content(let tags):
            WorkspaceTagTree(
                nodes: TagNavigationTree.build(from: tags),
                destination: $destination,
                collapsedPaths: $collapsedTagPaths
            )
        case .failure(let tags):
            if tags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("无法加载标签", systemImage: "exclamationmark.triangle")
                    Button("重试") {
                        Task { await tagsModel.load() }
                    }
                    .buttonStyle(.borderless)
                }
                .accessibilityIdentifier("workspace-tags-error")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Label {
                        Text("标签更新失败，正在显示上次结果")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    WorkspaceTagTree(
                        nodes: TagNavigationTree.build(from: tags),
                        destination: $destination,
                        collapsedPaths: $collapsedTagPaths
                    )
                }
            }
        }
    }
}

private struct WorkspaceSectionRow: View {
    let section: WorkspaceSection
    @Binding var destination: WorkspaceDestination?

    private var target: WorkspaceDestination { .section(section) }
    private var isSelected: Bool { destination == target }

    var body: some View {
        Button {
            destination = target
        } label: {
            Label(section.title, systemImage: section.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .tag(target)
        .accessibilityIdentifier("workspace-section-\(section.rawValue)")
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
    }
}

private struct WorkspaceTagTree: View {
    let nodes: [TagNavigationNode]
    @Binding var destination: WorkspaceDestination?
    @Binding var collapsedPaths: Set<String>

    var body: some View {
        ForEach(nodes) { node in
            WorkspaceTagTreeNode(
                node: node,
                depth: 0,
                destination: $destination,
                collapsedPaths: $collapsedPaths
            )
        }
    }
}

private struct WorkspaceTagTreeNode: View {
    let node: TagNavigationNode
    let depth: Int
    @Binding var destination: WorkspaceDestination?
    @Binding var collapsedPaths: Set<String>

    private var isCollapsed: Bool {
        collapsedPaths.contains(node.normalizedPath)
    }

    private var isExpanded: Bool {
        !isCollapsed
    }

    private var target: WorkspaceDestination? {
        node.summary.map { .tag($0.normalizedName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                disclosureButton
                tagButton
            }
            .padding(.leading, CGFloat(depth) * 14)
            if isExpanded {
                ForEach(node.children) { child in
                    WorkspaceTagTreeNode(
                        node: child,
                        depth: depth + 1,
                        destination: $destination,
                        collapsedPaths: $collapsedPaths
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var disclosureButton: some View {
        if node.children.isEmpty {
            Color.clear
                .frame(width: 18, height: 22)
                .accessibilityHidden(true)
        } else {
            Button {
                toggleExpansion()
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .frame(width: 18, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "收起" : "展开")
            .accessibilityValue(node.displayPath)
        }
    }

    @ViewBuilder
    private var tagButton: some View {
        if let summary = node.summary, let target {
            Button {
                destination = target
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "number")
                        .accessibilityHidden(true)
                    Text(node.displayName)
                    Spacer(minLength: 4)
                    Text("\(summary.noteCount)")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .tag(target)
            .accessibilityIdentifier("workspace-tag-\(summary.normalizedName)")
            .accessibilityLabel(node.displayPath)
            .accessibilityValue(
                "\(summary.noteCount) 篇笔记，\(destination == target ? "已选中" : "未选中")"
            )
            .accessibilityAddTraits(destination == target ? .isSelected : [])
            .listRowBackground(
                destination == target
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
        } else {
            Label(node.displayName, systemImage: "folder")
                .accessibilityLabel("\(node.displayPath)，分组")
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
        }
    }

    private func toggleExpansion() {
        var next = collapsedPaths
        if isCollapsed {
            next.remove(node.normalizedPath)
        } else {
            next.insert(node.normalizedPath)
        }
        collapsedPaths = next
    }
}

private struct WorkspaceLibraryColumn: View {
    let model: LibraryFeatureModel
    @Binding var selection: VaultPath?

    var body: some View {
        content
            .navigationTitle("笔记")
            .task { await model.load() }
            .refreshable { await model.refresh() }
            .accessibilityIdentifier("workspace-note-list")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载笔记")
        case .indexing(let notes):
            WorkspaceNoteList(
                notes: notes,
                selection: $selection,
                status: .indexing,
                retry: { Task { await model.refresh() } }
            )
        case .content(let notes):
            WorkspaceNoteList(notes: notes, selection: $selection)
        case .empty:
            ContentUnavailableView(
                "还没有笔记",
                systemImage: "doc.text",
                description: Text("这个 Vault 中还没有可读取的 Markdown 笔记。")
            )
            .accessibilityIdentifier("workspace-note-list-empty")
        case .failure(let failure, let notes):
            if notes.isEmpty {
                WorkspaceFailureView(
                    title: failure == .loadFailed ? "无法加载笔记" : "索引更新失败",
                    message: "请重试；如果问题持续，可在设置中重建索引。",
                    retry: { Task { await model.load() } }
                )
            } else {
                WorkspaceNoteList(
                    notes: notes,
                    selection: $selection,
                    status: .failure(
                        title: failure == .loadFailed ? "无法加载笔记" : "索引更新失败",
                        message: "现有笔记仍可阅读。请稍后重试更新。"
                    ),
                    retry: { Task { await model.refresh() } }
                )
            }
        }
    }
}

private struct WorkspaceRecentColumn: View {
    let model: SearchFeatureModel
    @Binding var selection: VaultPath?

    var body: some View {
        content
            .navigationTitle("最近")
            .task { await model.search("") }
            .refreshable { await model.search("") }
            .accessibilityIdentifier("workspace-recent-list")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载最近笔记")
        case .content(let hits):
            WorkspaceSearchResultList(hits: hits, selection: $selection)
        case .empty:
            ContentUnavailableView(
                "还没有最近笔记",
                systemImage: "clock",
                description: Text("最近修改的笔记会出现在这里。")
            )
            .accessibilityIdentifier("workspace-recent-empty")
        case .failure:
            WorkspaceFailureView(
                title: "无法加载最近笔记",
                message: "请稍后重试。",
                retry: { Task { await model.search("") } }
            )
        }
    }
}

private struct WorkspaceFavoritesColumn: View {
    let model: FavoritesFeatureModel
    @Binding var selection: VaultPath?

    var body: some View {
        content
            .navigationTitle("收藏")
            .task { await model.loadIfNeeded() }
            .refreshable { await model.reload() }
            .accessibilityIdentifier("workspace-favorites-list")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载收藏")
        case .content(let notes):
            WorkspaceNoteList(notes: notes, selection: $selection)
        case .empty:
            ContentUnavailableView(
                "还没有收藏",
                systemImage: "star",
                description: Text("在阅读栏中点击星标，可将笔记固定到这里。")
            )
            .accessibilityIdentifier("workspace-favorites-empty")
        case .failure(let failure, let notes):
            if notes.isEmpty {
                WorkspaceFailureView(
                    title: failure == .loadFailed ? "无法加载收藏" : "收藏更新失败",
                    message: "请重试；如果问题持续，收藏状态不会被覆盖。",
                    retry: { Task { await model.reload() } }
                )
            } else {
                WorkspaceNoteList(
                    notes: notes,
                    selection: $selection,
                    status: .failure(
                        title: failure == .loadFailed ? "无法加载收藏" : "收藏更新失败",
                        message: "现有收藏仍可打开，请稍后重试更新。"
                    ),
                    retry: { Task { await model.reload() } }
                )
            }
        }
    }
}

private struct WorkspaceSearchColumn: View {
    let model: SearchFeatureModel
    @Binding var selection: VaultPath?
    @State private var query = ""

    var body: some View {
        content
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "标题、正文或标签")
            .task(id: query) { await model.search(query) }
            .accessibilityIdentifier("workspace-search-list")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView(query.isEmpty ? "正在加载笔记" : "正在搜索")
        case .content(let hits):
            WorkspaceSearchResultList(hits: hits, selection: $selection)
        case .empty:
            if query.isEmpty {
                ContentUnavailableView(
                    "还没有笔记",
                    systemImage: "doc.text",
                    description: Text("输入条件搜索笔记。")
                )
                .accessibilityIdentifier("workspace-search-empty")
            } else {
                ContentUnavailableView.search(text: query)
                    .accessibilityIdentifier("workspace-search-no-results")
            }
        case .failure:
            WorkspaceFailureView(
                title: "无法搜索",
                message: "请修改查询或稍后重试。",
                retry: { Task { await model.search(query) } }
            )
        }
    }
}

private struct WorkspaceTaggedNotesColumn: View {
    let model: TagsFeatureModel
    let normalizedName: String
    @Binding var selection: VaultPath?

    var body: some View {
        content
            .navigationTitle(displayName)
            .task(id: normalizedName) { await loadSelectedTag() }
            .refreshable { await loadSelectedTag() }
            .accessibilityIdentifier("workspace-tag-note-list")
    }

    private var displayName: String {
        model.state.visibleTags.first { $0.normalizedName == normalizedName }?.displayName
            ?? normalizedName
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedTag?.normalizedName != normalizedName {
            ProgressView("正在加载笔记")
        } else {
            switch model.selectedNotesState {
            case .loading:
                ProgressView("正在加载笔记")
            case .content(let notes):
                WorkspaceNoteList(notes: notes, selection: $selection)
            case .empty:
                ContentUnavailableView(
                    "没有匹配的笔记",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("没有笔记使用此完整标签。")
                )
                .accessibilityIdentifier("workspace-tag-note-list-empty")
            case .failure:
                WorkspaceFailureView(
                    title: "无法加载标签笔记",
                    message: "请稍后重试。",
                    retry: { Task { await loadSelectedTag() } }
                )
            }
        }
    }

    private func loadSelectedTag() async {
        guard
            let tag = model.state.visibleTags.first(where: {
                $0.normalizedName == normalizedName
            })
        else {
            return
        }
        await model.select(tag: tag)
    }
}

private struct WorkspaceSearchResultList: View {
    let hits: [IndexSearchHit]
    @Binding var selection: VaultPath?

    var body: some View {
        List(selection: $selection) {
            ForEach(hits) { hit in
                SearchResultRow(hit: hit)
                    .tag(hit.path)
            }
        }
        .listStyle(.inset)
    }
}

private enum WorkspaceNoteListStatus: Equatable {
    case indexing
    case failure(title: String, message: String)
}

private struct WorkspaceNoteList: View {
    let notes: [IndexedNoteSummary]
    @Binding var selection: VaultPath?
    var status: WorkspaceNoteListStatus? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        List(selection: $selection) {
            if let status {
                Section {
                    WorkspaceNoteListStatusRow(status: status, retry: retry)
                }
            }
            Section("笔记") {
                ForEach(notes) { note in
                    LibraryNoteRow(note: note)
                        .tag(note.path)
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct WorkspaceNoteListStatusRow: View {
    let status: WorkspaceNoteListStatus
    let retry: (() -> Void)?

    var body: some View {
        switch status {
        case .indexing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在更新索引")
            }
            .accessibilityIdentifier("workspace-list-indexing")
        case .failure(let title, let message):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let retry {
                    Button("重试", action: retry)
                        .buttonStyle(.borderless)
                }
            }
            .accessibilityIdentifier("workspace-list-failure")
        }
    }
}

private struct WorkspaceFailureView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("重试", action: retry)
        }
        .accessibilityIdentifier("workspace-list-error")
    }
}

private struct VaultSelectionPrompt: View {
    let errorMessage: String?
    let openVault: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("选择 Obsidian Vault", systemImage: "folder.badge.plus")
        } description: {
            Text("BearObs 会读取你选择的本地 Markdown；只有点击保存时才会修改对应笔记。")
        } actions: {
            Button("打开 Vault…", action: openVault)
                .keyboardShortcut(.defaultAction)
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        // ContentUnavailableView 的标识会沿 AX 树覆盖到可聚焦的子元素，
        // 因此入口按钮的 identifier 必须放在这一层。
        .accessibilityIdentifier("open-vault-empty-state")
    }
}
