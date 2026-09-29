import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct FavoritesView: View {
    @State private var model: FavoritesFeatureModel
    private let readerSource: ReaderDataSource

    public init(
        model: FavoritesFeatureModel,
        readerSource: ReaderDataSource = .unavailable
    ) {
        _model = State(initialValue: model)
        self.readerSource = readerSource
    }

    public var body: some View {
        content
            .navigationTitle("收藏")
            .task { await model.loadIfNeeded() }
            .refreshable { await model.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载收藏")
                .accessibilityIdentifier("favorites-loading")
        case .content(let notes):
            notesList(notes, failure: nil)
        case .empty:
            ContentUnavailableView(
                "还没有收藏",
                systemImage: "star",
                description: Text("在 Reader 中点击星标，就能从这里快速打开笔记。")
            )
            .accessibilityIdentifier("favorites-empty")
        case .failure(let failure, let notes):
            if notes.isEmpty {
                failureView(failure)
            } else {
                notesList(notes, failure: failure)
            }
        }
    }

    private func notesList(
        _ notes: [IndexedNoteSummary],
        failure: FavoritesFailure?
    ) -> some View {
        List {
            if let failure {
                Section {
                    Label {
                        Text(failure.statusTitle)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("favorites-status")
                }
            }
            Section("已收藏") {
                ForEach(notes) { note in
                    NavigationLink {
                        ReaderView(
                            path: note.path,
                            source: readerSource,
                            favorites: model
                        )
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .accessibilityHidden(true)
                            LibraryNoteRow(note: note)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("favorites-list")
    }

    private func failureView(_ failure: FavoritesFailure) -> some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.message)
        } actions: {
            Button("重试") {
                Task { await model.reload() }
            }
        }
        .accessibilityIdentifier("favorites-error")
    }
}

extension FavoritesFailure {
    fileprivate var title: String {
        switch self {
        case .loadFailed:
            "无法加载收藏"
        case .updateFailed:
            "收藏更新失败"
        }
    }

    fileprivate var message: String {
        switch self {
        case .loadFailed:
            "请重试；如果问题持续，收藏状态不会被覆盖。"
        case .updateFailed:
            "现有收藏仍可打开，请稍后重试更新。"
        }
    }

    fileprivate var statusTitle: String {
        switch self {
        case .loadFailed:
            "收藏加载失败，正在显示上次结果"
        case .updateFailed:
            "收藏更新失败，正在显示上次结果"
        }
    }
}
