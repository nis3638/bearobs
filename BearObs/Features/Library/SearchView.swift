import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct SearchView: View {
    @State private var model: SearchFeatureModel
    @State private var query = ""
    private let readerSource: ReaderDataSource
    private let favorites: FavoritesFeatureModel?

    public init(
        model: SearchFeatureModel,
        readerSource: ReaderDataSource = .unavailable,
        favorites: FavoritesFeatureModel? = nil
    ) {
        _model = State(initialValue: model)
        self.readerSource = readerSource
        self.favorites = favorites
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("搜索")
                .searchable(text: $query, prompt: "标题、正文或标签")
                .task(id: query) { await model.search(query) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView(query.isEmpty ? "正在加载最近笔记" : "正在搜索")
                .accessibilityIdentifier("search-loading")
        case .content(let hits):
            List(hits) { hit in
                NavigationLink {
                    ReaderView(
                        path: hit.path,
                        source: readerSource,
                        favorites: favorites
                    )
                } label: {
                    SearchResultRow(hit: hit)
                }
            }
            .accessibilityIdentifier("search-results")
        case .empty:
            if query.isEmpty {
                ContentUnavailableView(
                    "还没有笔记",
                    systemImage: "doc.text",
                    description: Text("首次同步完成后，最近笔记会出现在这里。")
                )
                .accessibilityIdentifier("search-empty")
            } else {
                ContentUnavailableView.search(text: query)
                    .accessibilityIdentifier("search-empty")
            }
        case .failure:
            ContentUnavailableView {
                Label("无法搜索", systemImage: "exclamationmark.triangle")
            } description: {
                Text("请修改查询或稍后重试。")
            }
            .accessibilityIdentifier("search-error")
        }
    }
}

public struct SearchResultRow: View {
    let hit: IndexSearchHit
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(hit: IndexSearchHit) {
        self.hit = hit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleAndDate
            if !hit.preview.isEmpty {
                Text(hit.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
            }
            if hit.parseStatus != .complete {
                Label {
                    Text(
                        hit.parseStatus == .degraded
                            ? "部分内容未能索引"
                            : "内容无法索引"
                    )
                    .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                .font(.caption2.weight(.medium))
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
        Text(hit.title)
            .font(.headline)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    private var modifiedDate: some View {
        Text("修改于 \(hit.modifiedAt, style: .relative)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
