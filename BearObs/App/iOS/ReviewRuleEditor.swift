import SwiftUI

#if SWIFT_PACKAGE
    import BearObsDomain
#endif

/// REQ-005 FR-002.2/FR-002.6：回顾规则设置与调整。
///
/// 内容范围用分段选择，选「含标签 / 排除标签」时展开标签选择，未选标签时
/// 完成按钮不可用；时间范围五个选项；数量步进器步长 4（4...24）。修改既有
/// 规则时确认前弹出「按新规则重新抽取今日回顾？」，取消不调用 `onConfirm`，
/// 规则与批次保持不变；首次设置不弹确认。
struct ReviewRuleEditor: View {
    let initialRule: ReviewRule?
    let availableTags: [String]
    let onConfirm: (ReviewRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scopeMode: ScopeMode
    @State private var selectedTag: String
    @State private var timeScope: ReviewRule.TimeScope
    @State private var dailyCount: Int
    @State private var isRedrawConfirmationPresented = false

    private enum ScopeMode: Hashable {
        case all
        case including
        case excluding
        case untagged
    }

    init(
        initialRule: ReviewRule?,
        availableTags: [String],
        onConfirm: @escaping (ReviewRule) -> Void
    ) {
        self.initialRule = initialRule
        self.availableTags = availableTags
        self.onConfirm = onConfirm
        switch initialRule?.contentScope {
        case .includingTag(let tag):
            _scopeMode = State(initialValue: .including)
            _selectedTag = State(initialValue: tag)
        case .excludingTag(let tag):
            _scopeMode = State(initialValue: .excluding)
            _selectedTag = State(initialValue: tag)
        case .untagged:
            _scopeMode = State(initialValue: .untagged)
            _selectedTag = State(initialValue: "")
        case .all, nil:
            _scopeMode = State(initialValue: .all)
            _selectedTag = State(initialValue: "")
        }
        _timeScope = State(initialValue: initialRule?.timeScope ?? .all)
        _dailyCount = State(
            initialValue: initialRule?.dailyCount ?? ReviewRule.defaultDailyCount
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容范围") {
                    Picker(
                        "内容范围",
                        selection: $scopeMode
                    ) {
                        Text("全部").tag(ScopeMode.all)
                        Text("含标签").tag(ScopeMode.including)
                        Text("排除标签").tag(ScopeMode.excluding)
                        Text("无标签").tag(ScopeMode.untagged)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("review-rule-content-scope")
                    if needsTagSelection {
                        tagSelection
                    }
                }
                Section("时间范围") {
                    Picker("时间范围", selection: $timeScope) {
                        Text("全部").tag(ReviewRule.TimeScope.all)
                        Text("一年内").tag(ReviewRule.TimeScope.pastYear)
                        Text("半年内").tag(ReviewRule.TimeScope.pastSixMonths)
                        Text("三个月内").tag(ReviewRule.TimeScope.pastThreeMonths)
                        Text("一个月内").tag(ReviewRule.TimeScope.pastMonth)
                    }
                    .accessibilityIdentifier("review-rule-time-scope")
                }
                Section("数量") {
                    Stepper(
                        value: $dailyCount,
                        in: dailyCountRange,
                        step: 4
                    ) {
                        Text("每天 \(dailyCount) 条")
                    }
                    .accessibilityIdentifier("review-rule-daily-count")
                }
            }
            .navigationTitle(initialRule == nil ? "规则设置" : "调整规则")
            .toolbar {
                if initialRule != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .accessibilityIdentifier("review-rule-cancel")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: handleDone)
                        .disabled(!isSubmittable)
                        .accessibilityIdentifier("review-rule-done")
                }
            }
            .confirmationDialog(
                ReviewCopy.redrawConfirmation,
                isPresented: $isRedrawConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("重新抽取", action: confirm)
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - 草稿规则

    private var needsTagSelection: Bool {
        scopeMode == .including || scopeMode == .excluding
    }

    /// 步长 4、范围 4...24，与 `ReviewRule` 的约束一致（REQ-005 §9.2）。
    private var dailyCountRange: ClosedRange<Int> {
        ReviewRule.allowedDailyCounts.min()!...ReviewRule.allowedDailyCounts.max()!
    }

    private var isSubmittable: Bool {
        draftRule?.isSubmittable ?? false
    }

    private var draftRule: ReviewRule? {
        let contentScope: ReviewRule.ContentScope
        switch scopeMode {
        case .all: contentScope = .all
        case .untagged: contentScope = .untagged
        case .including: contentScope = .includingTag(selectedTag)
        case .excluding: contentScope = .excludingTag(selectedTag)
        }
        return try? ReviewRule(
            contentScope: contentScope,
            timeScope: timeScope,
            dailyCount: dailyCount
        )
    }

    @ViewBuilder
    private var tagSelection: some View {
        if availableTags.isEmpty {
            Text("这个 Vault 还没有可选的标签。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("review-rule-tags-empty")
        } else {
            Picker("标签", selection: $selectedTag) {
                ForEach(availableTags, id: \.self) { tag in
                    Text("#\(tag)").tag(tag)
                }
            }
            .accessibilityIdentifier("review-rule-tag-picker")
        }
    }

    // MARK: - 确认

    private func handleDone() {
        if initialRule == nil {
            confirm()
        } else {
            isRedrawConfirmationPresented = true
        }
    }

    private func confirm() {
        guard let rule = draftRule else { return }
        onConfirm(rule)
        dismiss()
    }
}
