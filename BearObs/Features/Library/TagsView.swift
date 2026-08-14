import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct TagsView: View {
    @State private var model: TagsFeatureModel
    private let readerSource: ReaderDataSource

    public init(model: TagsFeatureModel, readerSource: ReaderDataSource = .unavailable) {
        _model = State(initialValue: model)
        self.readerSource = readerSource
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("标签")
                .task { await model.load() }
                .refreshable { await model.load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载标签")
                .accessibilityIdentifier("tags-loading")
        case .content(let tags):
            tagsList(tags, showsFailure: false)
        case .empty:
            ContentUnavailableView(
                "还没有标签",
                systemImage: "number",
                description: Text("笔记中的标签会自动汇总到这里。")
            )
            .accessibilityIdentifier("tags-empty")
        case .failure(let tags):
            if tags.isEmpty {
                ContentUnavailableView {
                    Label("无法加载标签", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("请重试；如果问题持续，可在设置中重建索引。")
                } actions: {
                    Button("重试") { Task { await model.load() } }
                }
                .accessibilityIdentifier("tags-error")
            } else {
                tagsList(tags, showsFailure: true)
            }
        }
    }

    private func tagsList(_ tags: [IndexedTagSummary], showsFailure: Bool) -> some View {
        List {
            if showsFailure {
                Section {
                    Label("标签更新失败，正在显示上次结果", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            ForEach(tags) { tag in
                NavigationLink {
                    TaggedNotesView(
                        model: model.notesModel(for: tag),
                        readerSource: readerSource
                    )
                } label: {
                    HStack {
                        Label(tag.displayName, systemImage: "number")
                        Spacer()
                        Text("\(tag.noteCount) 篇")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("tags-list")
    }
}

private struct TaggedNotesView: View {
    @State var model: TaggedNotesFeatureModel
    let readerSource: ReaderDataSource

    var body: some View {
        content
            .navigationTitle(model.tag.displayName)
            .task { await model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("正在加载笔记")
        case .content(let notes):
            List(notes) { note in
                NavigationLink {
                    ReaderView(path: note.path, source: readerSource)
                } label: {
                    LibraryNoteRow(note: note)
                }
            }
            .accessibilityIdentifier("tagged-notes-list")
        case .empty:
            ContentUnavailableView("没有匹配的笔记", systemImage: "doc.text.magnifyingglass")
        case .failure:
            ContentUnavailableView {
                Label("无法加载笔记", systemImage: "exclamationmark.triangle")
            } description: {
                Text("请返回后重试。")
            }
        }
    }
}
