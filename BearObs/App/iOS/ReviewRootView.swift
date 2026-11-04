import SwiftUI

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsLibrary
#endif

/// REQ-005 FR-002 固定文案（§3 共享约定：文案集中在枚举里）。
enum ReviewCopy {
    static let adjustRule = "调整规则"
    static let persistenceFailed = "本次回顾未能保存"
    static let emptyCandidates = "没有符合规则的笔记"
    static let redrawConfirmation = "按新规则重新抽取今日回顾？"
    static func insufficient(count: Int) -> String {
        "符合规则的只有 \(count) 条"
    }
}

/// REQ-005 FR-002：每日回顾页。未设置规则时进入规则设置；已设置时展示
/// 当日批次，顶部一行规则摘要与「调整规则」，点批次行推入与卡片流相同的
/// 阅读面。候选来自既有索引状态与标签查询，抽取与落盘由
/// `ReviewSessionModel` 完成；本视图不写索引、不写 Vault。
struct ReviewRootView: View {
    let environment: AppEnvironment

    @State private var model: ReviewSessionModel?
    @State private var tagsByPath: [VaultPath: [String]] = [:]
    @State private var isEditorPresented = false
    @State private var selection: VaultPath?
    @State private var isSessionLoading = false

    var body: some View {
        Group {
            if let model {
                content(model)
            } else if environment.reviewState == nil || environment.vaultID == nil {
                ContentUnavailableView(
                    "回顾暂不可用",
                    systemImage: "sparkles",
                    description: Text("无法准备回顾状态，请重新打开 Vault。")
                )
                .accessibilityIdentifier("review-root-unavailable")
            } else {
                ProgressView("正在加载回顾")
                    .accessibilityIdentifier("review-root-loading")
            }
        }
        .navigationTitle("回顾")
        .accessibilityIdentifier("review-root")
        .navigationDestination(item: $selection) { path in
            ReaderView(
                path: path,
                source: environment.readerSource,
                favorites: environment.favoritesModel,
                editorSource: nil
            )
        }
        .task { await loadIfNeeded() }
    }

    @ViewBuilder
    private func content(_ model: ReviewSessionModel) -> some View {
        if model.rule == nil {
            ReviewRuleEditor(
                initialRule: nil,
                availableTags: availableTags,
                onConfirm: { rule in
                    Task { await applyRule(rule) }
                }
            )
        } else {
            batchPage(model)
                .sheet(isPresented: $isEditorPresented) {
                    ReviewRuleEditor(
                        initialRule: model.rule,
                        availableTags: availableTags,
                        onConfirm: { rule in
                            Task { await applyRule(rule) }
                        }
                    )
                }
        }
    }

    // MARK: - 批次页

    @ViewBuilder
    private func batchPage(_ model: ReviewSessionModel) -> some View {
        let paths = model.batch?.orderedPaths ?? []
        if paths.isEmpty {
            ContentUnavailableView {
                Label(ReviewCopy.emptyCandidates, systemImage: "sparkles")
            } actions: {
                Button(ReviewCopy.adjustRule) { isEditorPresented = true }
            }
            .accessibilityIdentifier("review-batch-empty")
        } else {
            batchList(model, paths: paths)
        }
    }

    private func batchList(
        _ model: ReviewSessionModel,
        paths: [String]
    ) -> some View {
        List {
            Section {
                HStack {
                    Text(ruleSummary(model.rule))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(ReviewCopy.adjustRule) { isEditorPresented = true }
                        .font(.subheadline)
                        .accessibilityIdentifier("review-adjust-rule")
                }
                if model.persistenceFailed {
                    Label(ReviewCopy.persistenceFailed, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("review-persistence-failed")
                }
            }
            Section {
                ForEach(paths, id: \.self) { path in
                    Button {
                        selection = try? VaultPath(decodedRelativePath: path)
                    } label: {
                        Text(title(for: path))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("review-batch-row-\(path)")
                }
                if let insufficient = insufficientCount(model) {
                    Text(ReviewCopy.insufficient(count: insufficient))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("review-batch-insufficient")
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("review-batch-list")
    }

    // MARK: - 数据装配

    /// 首次进入先装配候选，就绪后才发布 `model`：规则编辑器不会出现在候选
    /// 加载完成之前，避免空候选集被确认成当日批次并落盘。已有会话时再次
    /// 进入按当天日期复查（REQ-005 §5：过零点后重新抽取，同一天复用既有
    /// 批次），复查复用已装载的候选投影，不重查标签索引。
    private func loadIfNeeded() async {
        guard
            !isSessionLoading,
            let store = environment.reviewState,
            let vaultID = environment.vaultID
        else { return }
        if let model {
            await model.open(today: Date(), candidates: makeCandidates())
            return
        }
        isSessionLoading = true
        defer { isSessionLoading = false }
        let session = ReviewSessionModel(store: store, vaultID: vaultID)
        await assemble(session)
        model = session
    }

    private func assemble(_ session: ReviewSessionModel) async {
        await environment.libraryModel.load()
        await environment.tagsModel.loadIfNeeded()
        await rebuildTagIndex()
        await session.open(today: Date(), candidates: makeCandidates())
    }

    private func applyRule(_ rule: ReviewRule) async {
        guard let model else { return }
        await model.updateRule(rule, today: Date(), candidates: makeCandidates())
    }

    private var availableTags: [String] {
        environment.tagsModel.state.visibleTags.map(\.normalizedName)
    }

    /// 候选 = 已索引笔记 + 该路径的完整标签身份 + 可读性（解析失败不进入候选，
    /// 由 `ReviewDrawing` 过滤）；顺序沿用索引的修改时间倒序。
    private func makeCandidates() -> [ReviewCandidate] {
        environment.libraryModel.state.visibleNotes.map { note in
            ReviewCandidate(
                path: note.path.description,
                modifiedAt: note.modifiedAt,
                tags: Set(tagsByPath[note.path] ?? []),
                isReadable: note.parseStatus != .failed
            )
        }
    }

    /// 卡片标签来自既有标签查询：先取全部标签，再按标签取笔记并反转为
    /// 「路径 → 完整标签身份」。不新增索引列，也不改动索引 schema。
    private func rebuildTagIndex() async {
        let tags = environment.tagsModel.state.visibleTags
        var map: [VaultPath: [String]] = [:]
        for tag in tags {
            let taggedModel = environment.tagsModel.notesModel(for: tag)
            await taggedModel.load()
            guard case .content(let notes) = taggedModel.state else { continue }
            for note in notes {
                map[note.path, default: []].append(tag.normalizedName)
            }
        }
        tagsByPath = map
    }

    // MARK: - 展示辅助

    private func insufficientCount(_ model: ReviewSessionModel) -> Int? {
        guard
            let rule = model.rule,
            let batch = model.batch
        else { return nil }
        let count = batch.orderedPaths.count
        guard count > 0, count < rule.dailyCount else { return nil }
        return count
    }

    private func title(for path: String) -> String {
        let summary = environment.libraryModel.state.visibleNotes
            .first { $0.path.description == path }
        if let summary, !summary.title.isEmpty {
            return summary.title
        }
        return fileName(of: path)
    }

    private func fileName(of path: String) -> String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if name.hasSuffix(".md") {
            return String(name.dropLast(3))
        }
        return name
    }

    private func ruleSummary(_ rule: ReviewRule?) -> String {
        guard let rule else { return "" }
        let content: String
        switch rule.contentScope {
        case .all: content = "全部笔记"
        case .includingTag(let tag): content = "含 #\(tag)"
        case .excludingTag(let tag): content = "排除 #\(tag)"
        case .untagged: content = "无标签笔记"
        }
        let time: String
        switch rule.timeScope {
        case .all: time = "全部时间"
        case .pastYear: time = "一年内"
        case .pastSixMonths: time = "半年内"
        case .pastThreeMonths: time = "三个月内"
        case .pastMonth: time = "一个月内"
        }
        return "\(content) · \(time) · 每天 \(rule.dailyCount) 条"
    }
}
