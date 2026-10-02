import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct LibraryView: View {
    @State private var model: LibraryFeatureModel
    private let readerSource: ReaderDataSource
    private let favoritesModel: FavoritesFeatureModel?
    private let recentModel: SearchFeatureModel?

    public init(
        model: LibraryFeatureModel,
        readerSource: ReaderDataSource = .unavailable,
        favoritesModel: FavoritesFeatureModel? = nil,
        recentModel: SearchFeatureModel? = nil
    ) {
        _model = State(initialValue: model)
        self.readerSource = readerSource
        self.favoritesModel = favoritesModel
        self.recentModel = recentModel
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("笔记")
                .task { await model.load() }
                .refreshable { await model.refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载笔记")
                .accessibilityIdentifier("library-loading")
        case .indexing(let notes):
            notesList(notes, status: .indexing)
        case .content(let notes):
            notesList(notes, status: nil)
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
                    description: Text("首次同步完成后，笔记会出现在这里。")
                )
                .accessibilityIdentifier("library-empty")
            }
        case .failure(let failure, let notes):
            if notes.isEmpty {
                failureView(failure)
            } else {
                notesList(notes, status: .failure(failure))
            }
        }
    }

    private func notesList(_ notes: [IndexedNoteSummary], status: LibraryListStatus?) -> some View {
        List {
            if favoritesModel != nil || recentModel != nil {
                Section("浏览") {
                    if let recentModel {
                        NavigationLink {
                            RecentView(
                                model: recentModel,
                                readerSource: readerSource,
                                favorites: favoritesModel
                            )
                        } label: {
                            Label("最近", systemImage: "clock")
                        }
                        .accessibilityIdentifier("library-recent-entry")
                    }
                    if let favoritesModel {
                        NavigationLink {
                            FavoritesView(
                                model: favoritesModel,
                                readerSource: readerSource
                            )
                        } label: {
                            Label("收藏", systemImage: "star")
                        }
                        .accessibilityIdentifier("library-favorites-entry")
                    }
                }
            }
            if model.availability.unavailableCount > 0 {
                Section {
                    LibraryUnavailableSourcesRow(count: model.availability.unavailableCount)
                }
            }
            if let status {
                Section {
                    LibraryStatusRow(status: status) {
                        Task { await model.refresh() }
                    }
                }
            }
            Section("全部笔记") {
                ForEach(notes) { note in
                    NavigationLink {
                        ReaderView(
                            path: note.path,
                            source: readerSource,
                            favorites: favoritesModel
                        )
                    } label: {
                        LibraryNoteRow(
                            note: note,
                            isStale: model.availability.staleNotePaths.contains(note.path)
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("library-list")
    }

    private func failureView(_ failure: LibraryFailure) -> some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            Button("重试") {
                Task { await model.load() }
            }
        }
        .accessibilityIdentifier("library-error")
    }
}

private enum LibraryListStatus {
    case indexing
    case failure(LibraryFailure)
}

private struct LibraryStatusRow: View {
    let status: LibraryListStatus
    let retry: () -> Void

    var body: some View {
        switch status {
        case .indexing:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("正在更新索引")
                    .font(.subheadline.weight(.medium))
            }
            .accessibilityIdentifier("library-indexing")
        case .failure(let failure):
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(failure.title)
                        .font(.subheadline.weight(.semibold))
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("重试", action: retry)
                    .buttonStyle(.borderless)
            }
        }
    }
}

public struct LibraryNoteRow: View {
    let note: IndexedNoteSummary
    let isStale: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(note: IndexedNoteSummary, isStale: Bool = false) {
        self.note = note
        self.isStale = isStale
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                titleAndDate
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
                if note.parseStatus != .complete {
                    Label {
                        Text(note.parseStatus.label)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: note.parseStatus.symbolName)
                            .foregroundStyle(statusColor)
                    }
                    .font(.caption2.weight(.medium))
                }
                if isStale {
                    Label("源文件暂不可用，显示已索引内容", systemImage: "icloud.slash")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("library-note-stale")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleAndDate: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                title
                modifiedDate
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                title
                Spacer(minLength: 8)
                modifiedDate
            }
        }
    }

    private var title: some View {
        Text(note.title)
            .font(.headline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    private var modifiedDate: some View {
        Text("修改于 \(note.modifiedAt, style: .relative)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch note.parseStatus {
        case .complete: .accentColor
        case .degraded: .orange
        case .failed: .red
        }
    }
}

public enum LibraryAvailabilityPresentation {
    public static func title(count: Int) -> String {
        "有 \(count) 个源文件暂不可用"
    }

    public static let message = "现有索引内容仍可阅读；文件恢复后，下拉刷新即可更新。"
    public static let retryTitle = "重试"
}

public struct LibraryUnavailableSourcesView: View {
    public let count: Int
    private let retry: () -> Void

    public init(count: Int, retry: @escaping () -> Void) {
        self.count = count
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label(
                LibraryAvailabilityPresentation.title(count: count),
                systemImage: "icloud.slash"
            )
        } description: {
            Text(LibraryAvailabilityPresentation.message)
        } actions: {
            Button(LibraryAvailabilityPresentation.retryTitle, action: retry)
        }
        .accessibilityIdentifier("library-source-unavailable")
    }
}

public struct LibraryUnavailableSourcesRow: View {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(LibraryAvailabilityPresentation.title(count: count))
                    .font(.subheadline.weight(.semibold))
                Text(LibraryAvailabilityPresentation.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "icloud.slash")
                .foregroundStyle(.orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-source-unavailable-warning")
    }
}

enum LibraryAccessibilityText {
    static func favoriteButtonLabel(
        isReady: Bool,
        isFavorite: Bool,
        isUpdating: Bool = false
    ) -> String {
        if isUpdating { return "正在更新收藏状态" }
        guard isReady else { return "正在读取收藏状态" }
        return isFavorite ? "取消收藏" : "收藏"
    }

    static func favoriteButtonHint(isFavorite: Bool) -> String {
        isFavorite ? "将这篇笔记从收藏中移除" : "将这篇笔记添加到收藏"
    }

    static func tagLabel(name: String, noteCount: Int) -> String {
        "\(name)，\(noteCount) 篇笔记"
    }
}

extension IndexedNoteParseStatus {
    fileprivate var label: String {
        switch self {
        case .complete: "索引完整"
        case .degraded: "部分内容未能索引"
        case .failed: "内容无法索引"
        }
    }

    fileprivate var symbolName: String {
        switch self {
        case .complete: "checkmark.circle"
        case .degraded: "exclamationmark.circle"
        case .failed: "xmark.circle"
        }
    }
}

extension LibraryFailure {
    fileprivate var title: String {
        switch self {
        case .loadFailed: "无法加载笔记"
        case .refreshFailed: "索引更新失败"
        }
    }

    fileprivate var message: String {
        switch self {
        case .loadFailed: "请重试；如果问题持续，可在设置中重建索引。"
        case .refreshFailed: "现有笔记仍可阅读。请稍后重试更新。"
        }
    }
}
