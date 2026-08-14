import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct SearchView: View {
    @State private var model: SearchFeatureModel
    @State private var query = ""
    private let readerSource: ReaderDataSource

    public init(model: SearchFeatureModel, readerSource: ReaderDataSource = .unavailable) {
        _model = State(initialValue: model)
        self.readerSource = readerSource
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
                    ReaderView(path: hit.path, source: readerSource)
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

private struct SearchResultRow: View {
    let hit: IndexSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(hit.modifiedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !hit.preview.isEmpty {
                Text(hit.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if hit.parseStatus != .complete {
                Label(
                    hit.parseStatus == .degraded ? "部分内容未能索引" : "内容无法索引",
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
