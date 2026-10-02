import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public enum TagListPresentation {
    public static let staleWarning = "标签更新失败，正在显示上次结果"

    public static func accessibilityLabel(name: String, noteCount: Int) -> String {
        LibraryAccessibilityText.tagLabel(name: name, noteCount: noteCount)
    }

    public static func accessibilityValue(isSelected: Bool) -> String {
        isSelected ? "已选中" : "未选中"
    }

    public static func selectionIndicatorName(isSelected: Bool) -> String? {
        isSelected ? "checkmark" : nil
    }
}

public struct TagsView: View {
    @State private var model: TagsFeatureModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let readerSource: ReaderDataSource
    private let favorites: FavoritesFeatureModel?

    public init(
        model: TagsFeatureModel,
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
                    Label {
                        Text(TagListPresentation.staleWarning)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            ForEach(tags) { tag in
                NavigationLink {
                    TaggedNotesView(
                        model: model,
                        tag: tag,
                        readerSource: readerSource,
                        favorites: favorites
                    )
                } label: {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(tag.displayName, systemImage: "number")
                                Text("\(tag.noteCount) 篇")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack {
                                Label(tag.displayName, systemImage: "number")
                                Spacer(minLength: 8)
                                Text("\(tag.noteCount) 篇")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        TagListPresentation.accessibilityLabel(
                            name: tag.displayName,
                            noteCount: tag.noteCount
                        )
                    )
                }
            }
        }
        .accessibilityIdentifier("tags-list")
    }
}

private struct TaggedNotesView: View {
    let model: TagsFeatureModel
    let tag: IndexedTagSummary
    let readerSource: ReaderDataSource
    let favorites: FavoritesFeatureModel?

    var body: some View {
        content
            .navigationTitle(tag.displayName)
            .task(id: tag.normalizedName) { await model.select(tag: tag) }
    }

    @ViewBuilder
    private var content: some View {
        if model.selectedTag?.normalizedName != tag.normalizedName {
            ProgressView("正在加载笔记")
        } else {
            switch model.selectedNotesState {
            case .loading:
                ProgressView("正在加载笔记")
            case .content(let notes):
                List(notes) { note in
                    NavigationLink {
                        ReaderView(
                            path: note.path,
                            source: readerSource,
                            favorites: favorites
                        )
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
                } actions: {
                    Button("重试") {
                        Task { await model.select(tag: tag) }
                    }
                }
                .accessibilityIdentifier("tagged-notes-error")
            }
        }
    }
}
