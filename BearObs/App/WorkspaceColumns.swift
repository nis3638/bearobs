import SwiftUI

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLibrary
#endif

/// Workspace shell building blocks shared by the macOS three-column shell and
/// the iOS shell (compact tabs + iPad three-column). The information structure
/// and selection semantics are owned by REQ-001 and must not fork per
/// platform; the shells only choose how these pieces are assembled.
/// Platform seams are recorded in REQ-004 §7 / ADR-010.

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

    var restorationID: String { id }

    static func restore(from id: String?) -> WorkspaceDestination {
        guard let id else { return .section(.notes) }
        if id.hasPrefix("section:"),
            let section = WorkspaceSection(rawValue: String(id.dropFirst("section:".count)))
        {
            return .section(section)
        }
        if id.hasPrefix("tag:") {
            let tag = String(id.dropFirst("tag:".count))
            if !tag.isEmpty { return .tag(tag) }
        }
        return .section(.notes)
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

struct WorkspaceSidebar: View {
    let tagsModel: TagsFeatureModel
    let availabilityModel: LibraryFeatureModel?
    @Binding var destination: WorkspaceDestination?
    @State private var isTagsExpanded = true
    @State private var collapsedTagPaths: Set<String> = []

    init(
        tagsModel: TagsFeatureModel,
        availabilityModel: LibraryFeatureModel? = nil,
        destination: Binding<WorkspaceDestination?>
    ) {
        self.tagsModel = tagsModel
        self.availabilityModel = availabilityModel
        _destination = destination
    }

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
        .task { await availabilityModel?.load() }
        .refreshable { await refreshTags() }
    }

    @ViewBuilder
    private var tagContent: some View {
        switch tagsModel.state {
        case .loading:
            ProgressView("正在加载标签")
                .accessibilityIdentifier("workspace-tags-loading")
        case .empty:
            if availability.unavailableCount > 0 {
                LibraryUnavailableSourcesRow(count: availability.unavailableCount)
            } else {
                Text("还没有标签")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace-tags-empty")
            }
        case .content(let tags):
            availabilityWarning
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
                availabilityWarning
                Label {
                    Text(TagListPresentation.staleWarning)
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

    @ViewBuilder
    private var availabilityWarning: some View {
        if availability.unavailableCount > 0 {
            LibraryUnavailableSourcesRow(count: availability.unavailableCount)
        }
    }

    private var availability: IndexAvailabilityState {
        availabilityModel?.availability
            ?? IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
    }

    private func refreshTags() async {
        await availabilityModel?.refresh()
        await tagsModel.load()
    }
}

struct WorkspaceSectionRow: View {
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

struct WorkspaceTagTree: View {
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

struct WorkspaceTagTreeNode: View {
    let node: TagNavigationNode
    let depth: Int
    @Binding var destination: WorkspaceDestination?
    @Binding var collapsedPaths: Set<String>
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isCollapsed: Bool {
        collapsedPaths.contains(node.normalizedPath)
    }

    private var isExpanded: Bool {
        !isCollapsed
    }

    private var target: WorkspaceDestination? {
        node.summary.map { .tag($0.normalizedName) }
    }

    private var isSelected: Bool {
        guard let target else { return false }
        return destination == target
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
                tagLabel(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .tag(target)
            .accessibilityIdentifier("workspace-tag-\(summary.normalizedName)")
            .accessibilityLabel(
                TagListPresentation.accessibilityLabel(
                    name: node.displayPath,
                    noteCount: summary.noteCount
                )
            )
            .accessibilityValue(TagListPresentation.accessibilityValue(isSelected: isSelected))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .listRowBackground(
                isSelected
                    ? Color.accentColor.opacity(0.18)
                    : Color.clear
            )
        } else {
            Label(node.displayName, systemImage: "folder")
                .accessibilityLabel("\(node.displayPath)，分组")
                .accessibilityValue(isExpanded ? "已展开" : "已收起")
        }
    }

    @ViewBuilder
    private func tagLabel(_ summary: IndexedTagSummary) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 6) {
                tagIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.displayName)
                        .lineLimit(nil)
                    Text("\(summary.noteCount) 篇")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                selectionIndicator
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                tagIcon
                Text(node.displayName)
                Spacer(minLength: 4)
                Text("\(summary.noteCount) 篇")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                selectionIndicator
            }
        }
    }

    private var tagIcon: some View {
        Image(systemName: "number")
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var selectionIndicator: some View {
        if let symbolName = TagListPresentation.selectionIndicatorName(isSelected: isSelected) {
            Image(systemName: symbolName)
                .accessibilityHidden(true)
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

struct WorkspaceLibraryColumn: View {
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
                availability: model.availability,
                status: .indexing,
                retry: { Task { await model.refresh() } }
            )
        case .content(let notes):
            WorkspaceNoteList(
                notes: notes,
                selection: $selection,
                availability: model.availability
            )
        case .empty:
            if model.availability.unavailableCount > 0 {
                LibraryUnavailableSourcesView(
                    count: model.availability.unavailableCount,
                    retry: { Task { await model.refresh() } }
                )
            } else {
                ContentUnavailableView(
                    "还没有笔记",
                    systemImage: "doc.text",
                    description: Text("这个 Vault 中还没有可读取的 Markdown 笔记。")
                )
                .accessibilityIdentifier("workspace-note-list-empty")
            }
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
                    availability: model.availability,
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

struct WorkspaceRecentColumn: View {
    let model: SearchFeatureModel
    let availabilityModel: LibraryFeatureModel?
    @Binding var selection: VaultPath?

    init(
        model: SearchFeatureModel,
        availabilityModel: LibraryFeatureModel? = nil,
        selection: Binding<VaultPath?>
    ) {
        self.model = model
        self.availabilityModel = availabilityModel
        _selection = selection
    }

    var body: some View {
        content
            .navigationTitle("最近")
            .task { await model.search("") }
            .task { await availabilityModel?.load() }
            .refreshable { await refresh() }
            .accessibilityIdentifier("workspace-recent-list")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载最近笔记")
        case .content(let hits):
            WorkspaceSearchResultList(
                hits: hits,
                selection: $selection,
                availability: availability
            )
        case .empty:
            if availability.unavailableCount > 0 {
                LibraryUnavailableSourcesView(
                    count: availability.unavailableCount,
                    retry: { Task { await refresh() } }
                )
            } else {
                ContentUnavailableView(
                    "还没有最近笔记",
                    systemImage: "clock",
                    description: Text("最近修改的笔记会出现在这里。")
                )
                .accessibilityIdentifier("workspace-recent-empty")
            }
        case .failure:
            WorkspaceFailureView(
                title: "无法加载最近笔记",
                message: "请稍后重试。",
                retry: { Task { await model.search("") } }
            )
        }
    }

    private var availability: IndexAvailabilityState {
        availabilityModel?.availability
            ?? IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
    }

    private func refresh() async {
        await availabilityModel?.refresh()
        await model.search("")
    }
}

struct WorkspaceFavoritesColumn: View {
    let model: FavoritesFeatureModel
    let availabilityModel: LibraryFeatureModel?
    @Binding var selection: VaultPath?

    init(
        model: FavoritesFeatureModel,
        availabilityModel: LibraryFeatureModel? = nil,
        selection: Binding<VaultPath?>
    ) {
        self.model = model
        self.availabilityModel = availabilityModel
        _selection = selection
    }

    var body: some View {
        content
            .navigationTitle("收藏")
            .task { await model.loadIfNeeded() }
            .task { await availabilityModel?.load() }
            .refreshable { await refresh() }
            .accessibilityIdentifier("workspace-favorites-list")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载收藏")
        case .content(let notes):
            WorkspaceNoteList(
                notes: notes,
                selection: $selection,
                availability: availability
            )
        case .empty:
            if availability.unavailableCount > 0 {
                LibraryUnavailableSourcesView(
                    count: availability.unavailableCount,
                    retry: { Task { await refresh() } }
                )
            } else {
                ContentUnavailableView(
                    "还没有收藏",
                    systemImage: "star",
                    description: Text("在阅读栏中点击星标，可将笔记固定到这里。")
                )
                .accessibilityIdentifier("workspace-favorites-empty")
            }
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
                    availability: availability,
                    status: .failure(
                        title: failure == .loadFailed ? "无法加载收藏" : "收藏更新失败",
                        message: "现有收藏仍可打开，请稍后重试更新。"
                    ),
                    retry: { Task { await model.reload() } }
                )
            }
        }
    }

    private var availability: IndexAvailabilityState {
        availabilityModel?.availability
            ?? IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
    }

    private func refresh() async {
        await availabilityModel?.refresh()
        await model.reload()
    }
}

struct WorkspaceSearchColumn: View {
    let model: SearchFeatureModel
    let availabilityModel: LibraryFeatureModel?
    @Binding var selection: VaultPath?
    @State private var query = ""

    init(
        model: SearchFeatureModel,
        availabilityModel: LibraryFeatureModel? = nil,
        selection: Binding<VaultPath?>
    ) {
        self.model = model
        self.availabilityModel = availabilityModel
        _selection = selection
    }

    var body: some View {
        content
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "标题、正文或标签")
            .task(id: query) { await model.search(query) }
            .task { await availabilityModel?.load() }
            .refreshable { await refresh() }
            .accessibilityIdentifier("workspace-search-list")
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView(query.isEmpty ? "正在加载笔记" : "正在搜索")
        case .content(let hits):
            WorkspaceSearchResultList(
                hits: hits,
                selection: $selection,
                availability: availability
            )
        case .empty:
            if availability.unavailableCount > 0 {
                LibraryUnavailableSourcesView(
                    count: availability.unavailableCount,
                    retry: { Task { await refresh() } }
                )
            } else if query.isEmpty {
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

    private var availability: IndexAvailabilityState {
        availabilityModel?.availability
            ?? IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
    }

    private func refresh() async {
        await availabilityModel?.refresh()
        await model.search(query)
    }
}

struct WorkspaceTaggedNotesColumn: View {
    let model: TagsFeatureModel
    let availabilityModel: LibraryFeatureModel?
    let normalizedName: String
    @Binding var selection: VaultPath?

    init(
        model: TagsFeatureModel,
        availabilityModel: LibraryFeatureModel? = nil,
        normalizedName: String,
        selection: Binding<VaultPath?>
    ) {
        self.model = model
        self.availabilityModel = availabilityModel
        self.normalizedName = normalizedName
        _selection = selection
    }

    var body: some View {
        content
            .navigationTitle(displayName)
            .task(id: matchedTag?.id) { await loadSelectedTag() }
            .task { await availabilityModel?.load() }
            .refreshable { await refresh() }
            .accessibilityIdentifier("workspace-tag-note-list")
    }

    private var displayName: String {
        model.state.visibleTags.first { $0.normalizedName == normalizedName }?.displayName
            ?? normalizedName
    }

    private var matchedTag: IndexedTagSummary? {
        model.state.visibleTags.first { $0.normalizedName == normalizedName }
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
                WorkspaceNoteList(
                    notes: notes,
                    selection: $selection,
                    availability: availability
                )
            case .empty:
                if availability.unavailableCount > 0 {
                    LibraryUnavailableSourcesView(
                        count: availability.unavailableCount,
                        retry: { Task { await refresh() } }
                    )
                } else {
                    ContentUnavailableView(
                        "没有匹配的笔记",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("没有笔记使用此完整标签。")
                    )
                    .accessibilityIdentifier("workspace-tag-note-list-empty")
                }
            case .failure:
                WorkspaceFailureView(
                    title: "无法加载标签笔记",
                    message: "请稍后重试。",
                    retry: { Task { await loadSelectedTag() } }
                )
            }
        }
    }

    private var availability: IndexAvailabilityState {
        availabilityModel?.availability
            ?? IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
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

    private func refresh() async {
        await availabilityModel?.refresh()
        await model.load()
        await loadSelectedTag()
    }
}

struct WorkspaceSearchResultList: View {
    let hits: [IndexSearchHit]
    @Binding var selection: VaultPath?
    var availability = IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])

    var body: some View {
        List(selection: $selection) {
            if availability.unavailableCount > 0 {
                Section {
                    LibraryUnavailableSourcesRow(count: availability.unavailableCount)
                }
            }
            Section {
                ForEach(hits) { hit in
                    SearchResultRow(
                        hit: hit,
                        isStale: availability.staleNotePaths.contains(hit.path)
                    )
                    .tag(hit.path)
                }
            }
        }
        .listStyle(.inset)
    }
}

enum WorkspaceNoteListStatus: Equatable {
    case indexing
    case failure(title: String, message: String)
}

struct WorkspaceNoteList: View {
    let notes: [IndexedNoteSummary]
    @Binding var selection: VaultPath?
    var availability = IndexAvailabilityState(unavailableCount: 0, staleNotePaths: [])
    var status: WorkspaceNoteListStatus? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        List(selection: $selection) {
            if availability.unavailableCount > 0 {
                Section {
                    LibraryUnavailableSourcesRow(count: availability.unavailableCount)
                }
            }
            if let status {
                Section {
                    WorkspaceNoteListStatusRow(status: status, retry: retry)
                }
            }
            Section("笔记") {
                ForEach(notes) { note in
                    LibraryNoteRow(
                        note: note,
                        isStale: availability.staleNotePaths.contains(note.path)
                    )
                    .tag(note.path)
                }
            }
        }
        .listStyle(.inset)
    }
}

struct WorkspaceNoteListStatusRow: View {
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

struct WorkspaceFailureView: View {
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

struct VaultSelectionPrompt: View {
    let descriptionText: String
    let errorMessage: String?
    let openVault: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("选择 Obsidian Vault", systemImage: "folder.badge.plus")
        } description: {
            Text(descriptionText)
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

struct VaultWorkspaceView: View {
    let environment: AppEnvironment
    private let destinationDidChange: (WorkspaceDestination?) -> Void
    private let selectedPathDidChange: (VaultPath?) -> Void
    @State private var destination: WorkspaceDestination?
    @State private var selectedPath: VaultPath?
    @State private var pendingPath: VaultPath?
    @State private var hasUnsavedEditorChanges = false
    @State private var isDiscardConfirmationPresented = false

    init(
        environment: AppEnvironment,
        initialDestination: WorkspaceDestination? = .section(.notes),
        initialSelectedPath: VaultPath? = nil,
        destinationDidChange: @escaping (WorkspaceDestination?) -> Void = { _ in },
        selectedPathDidChange: @escaping (VaultPath?) -> Void = { _ in }
    ) {
        self.environment = environment
        self.destinationDidChange = destinationDidChange
        self.selectedPathDidChange = selectedPathDidChange
        _destination = State(initialValue: initialDestination)
        _selectedPath = State(initialValue: initialSelectedPath)
    }

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(
                tagsModel: environment.tagsModel,
                availabilityModel: environment.libraryModel,
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
            destinationDidChange(nextDestination)
            guard case .section = nextDestination else { return }
            environment.tagsModel.clearTagSelection()
        }
        .onChange(of: selectedPath) { _, path in
            selectedPathDidChange(path)
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
                availabilityModel: environment.libraryModel,
                selection: selectionBinding
            )
        case .section(.favorites):
            WorkspaceFavoritesColumn(
                model: environment.favoritesModel,
                availabilityModel: environment.libraryModel,
                selection: selectionBinding
            )
        case .section(.search):
            WorkspaceSearchColumn(
                model: environment.searchModel,
                availabilityModel: environment.libraryModel,
                selection: selectionBinding
            )
        case .tag(let normalizedName):
            WorkspaceTaggedNotesColumn(
                model: environment.tagsModel,
                availabilityModel: environment.libraryModel,
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
