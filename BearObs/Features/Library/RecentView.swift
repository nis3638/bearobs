import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct RecentView: View {
    @State private var model: SearchFeatureModel
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
        content
            .navigationTitle("最近")
            .task { await model.search("") }
            .refreshable { await model.search("") }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载最近笔记")
                .accessibilityIdentifier("recent-loading")
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
            .accessibilityIdentifier("recent-list")
        case .empty:
            ContentUnavailableView(
                "还没有最近笔记",
                systemImage: "clock",
                description: Text("首次同步完成后，最近修改的笔记会出现在这里。")
            )
            .accessibilityIdentifier("recent-empty")
        case .failure:
            ContentUnavailableView {
                Label("无法加载最近笔记", systemImage: "exclamationmark.triangle")
            } description: {
                Text("请稍后重试。")
            } actions: {
                Button("重试") { Task { await model.search("") } }
            }
            .accessibilityIdentifier("recent-error")
        }
    }
}
