import SwiftUI

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsMarkdown
#endif

enum ReaderInternalRoute {
    static func url(for path: VaultPath) -> URL {
        var components = URLComponents()
        components.scheme = "bearobs"
        components.host = "note"
        components.queryItems = [URLQueryItem(name: "path", value: path.description)]
        return components.url!
    }

    static func path(from url: URL) -> VaultPath? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == "bearobs",
            components.host?.lowercased() == "note",
            components.user == nil,
            components.password == nil,
            components.port == nil,
            components.path.isEmpty,
            components.fragment == nil,
            let items = components.queryItems,
            items.count == 1,
            items[0].name == "path",
            let rawPath = items[0].value
        else {
            return nil
        }
        return try? VaultPath(decodedRelativePath: rawPath)
    }
}

public struct ReaderView: View {
    @State private var model: ReaderFeatureModel
    @State private var destination: VaultPath?
    @State private var editorModel: EditorFeatureModel?
    @State private var isDiscardConfirmationPresented = false
    @State private var readerScrollOffset: CGFloat = 0
    private let source: ReaderDataSource
    private let editorSource: EditorDataSource?
    private let onUnsavedChangesChanged: (Bool) -> Void
    private let requestedPath: VaultPath

    public init(
        model: ReaderFeatureModel,
        editorSource: EditorDataSource? = nil,
        onUnsavedChangesChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _model = State(initialValue: model)
        _editorModel = State(initialValue: nil)
        source = model.dataSource
        self.editorSource = editorSource
        self.onUnsavedChangesChanged = onUnsavedChangesChanged
        requestedPath = model.path
    }

    public init(
        path: VaultPath,
        source: ReaderDataSource,
        favorites: FavoritesFeatureModel? = nil,
        editorSource: EditorDataSource? = nil,
        onUnsavedChangesChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _model = State(
            initialValue: ReaderFeatureModel(
                path: path,
                source: source,
                favorites: favorites
            )
        )
        _editorModel = State(initialValue: nil)
        self.source = source
        self.editorSource = editorSource
        self.onUnsavedChangesChanged = onUnsavedChangesChanged
        requestedPath = path
    }

    public var body: some View {
        content
            .navigationTitle(title)
            .task(id: requestedPath) {
                if model.path != requestedPath {
                    editorModel = nil
                    isDiscardConfirmationPresented = false
                    destination = nil
                    model = ReaderFeatureModel(
                        path: requestedPath,
                        source: source,
                        favorites: model.favoritesModel
                    )
                }
                async let document: Void = model.load()
                async let favorite: Void = model.loadFavoriteStatus()
                _ = await (document, favorite)
            }
            .toolbar {
                if let editorModel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成", action: finishEditing)
                            .disabled(editorModel.isSaving)
                            .accessibilityIdentifier("inline-editor-finish-button")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { Task { await saveEditing() } }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!editorModel.isDirty || editorModel.isSaving)
                            .accessibilityIdentifier("inline-editor-save-button")
                    }
                } else if let editorSource {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            beginEditing(with: editorSource)
                        } label: {
                            Label("编辑", systemImage: "square.and.pencil")
                        }
                        .accessibilityIdentifier("reader-edit-button")
                    }
                }
                if model.hasFavorites {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.toggleFavorite() }
                        } label: {
                            Image(
                                systemName: model.isFavorite
                                    ? "star.fill"
                                    : "star"
                            )
                        }
                        .accessibilityLabel(
                            LibraryAccessibilityText.favoriteButtonLabel(
                                isReady: model.favoriteStatusIsReady,
                                isFavorite: model.isFavorite,
                                isUpdating: model.isUpdatingFavorite
                            )
                        )
                        .accessibilityHint(
                            model.favoriteStatusIsReady
                                ? LibraryAccessibilityText.favoriteButtonHint(
                                    isFavorite: model.isFavorite
                                )
                                : ""
                        )
                        .accessibilityIdentifier("reader-favorite-button")
                        .disabled(
                            !model.favoriteStatusIsReady || model.isUpdatingFavorite
                        )
                    }
                }
            }
            .confirmationDialog(
                "放弃未保存的修改？",
                isPresented: $isDiscardConfirmationPresented
            ) {
                Button("放弃修改", role: .destructive) { editorModel = nil }
                Button("继续编辑", role: .cancel) {}
            } message: {
                Text("这篇笔记的本地草稿尚未保存。")
            }
            .alert(
                "收藏未更新",
                isPresented: favoriteFailurePresented,
                actions: {
                    Button("好") { model.dismissFavoriteFailure() }
                },
                message: {
                    Text(favoriteFailureMessage)
                }
            )
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard let path = ReaderInternalRoute.path(from: url) else {
                        return .systemAction
                    }
                    destination = path
                    return .handled
                }
            )
            .navigationDestination(item: $destination) { path in
                ReaderView(
                    path: path,
                    source: source,
                    favorites: model.favoritesModel,
                    editorSource: editorSource,
                    onUnsavedChangesChanged: onUnsavedChangesChanged
                )
            }
            .onChange(of: editorModel?.isDirty) { _, isDirty in
                onUnsavedChangesChanged(isDirty ?? false)
            }
            .onDisappear { onUnsavedChangesChanged(false) }
    }

    @ViewBuilder
    private var content: some View {
        if let editorModel {
            InlineMarkdownEditor(
                model: editorModel,
                initialScrollOffset: readerScrollOffset,
                finishEditing: finishEditing,
                retryReaderLoad: { Task { await model.load() } }
            )
        } else {
            switch model.state {
            case .loading:
                ProgressView("正在打开笔记")
                    .accessibilityIdentifier("reader-loading")
            case .content(let document):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ReaderBlocksView(blocks: document.blocks)
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ReaderScrollOffsetPreferenceKey.self,
                                value: proxy.frame(in: .named("reader-scroll")).minY
                            )
                        }
                    )
                }
                .coordinateSpace(name: "reader-scroll")
                .onPreferenceChange(ReaderScrollOffsetPreferenceKey.self) { offset in
                    readerScrollOffset = max(0, -offset)
                }
                .accessibilityIdentifier("reader-content")
            case .failure:
                ContentUnavailableView {
                    Label("无法打开笔记", systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text("文件可能已移动、过大或暂时不可读取。")
                } actions: {
                    Button("重试") { Task { await model.load() } }
                }
                .accessibilityIdentifier("reader-error")
            }
        }
    }

    private var title: String {
        if case .content(let document) = model.state, !document.title.isEmpty {
            return document.title
        }
        return requestedPath.fileNameWithoutExtension
    }

    private var favoriteFailurePresented: Binding<Bool> {
        Binding(
            get: { model.favoriteFailure != nil },
            set: { if !$0 { model.dismissFavoriteFailure() } }
        )
    }

    private var favoriteFailureMessage: String {
        switch model.favoriteFailure {
        case .loadFailed:
            "当前无法读取收藏状态，请稍后重试。"
        case .updateFailed:
            "收藏没有保存成功，原状态已保留。"
        case nil:
            ""
        }
    }

    private func beginEditing(with source: EditorDataSource) {
        editorModel = EditorFeatureModel(path: requestedPath, source: source)
    }

    private func finishEditing() {
        guard let editorModel, !editorModel.isSaving else { return }
        if editorModel.isDirty {
            isDiscardConfirmationPresented = true
        } else {
            self.editorModel = nil
        }
    }

    private func saveEditing() async {
        guard let editorModel else { return }
        await editorModel.save()
        guard editorModel.failure == nil, !editorModel.isDirty else { return }
        await model.load()
    }
}

struct InlineMarkdownEditor: View {
    @Bindable var model: EditorFeatureModel
    let initialScrollOffset: CGFloat
    let finishEditing: () -> Void
    let retryReaderLoad: () -> Void

    init(
        model: EditorFeatureModel,
        initialScrollOffset: CGFloat = 0,
        finishEditing: @escaping () -> Void,
        retryReaderLoad: @escaping () -> Void
    ) {
        self.model = model
        self.initialScrollOffset = initialScrollOffset
        self.finishEditing = finishEditing
        self.retryReaderLoad = retryReaderLoad
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 760, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
        }
        .task {
            if model.state == .idle { await model.load() }
        }
        .accessibilityIdentifier("inline-markdown-editor")
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView("正在载入原始 Markdown")
                .accessibilityIdentifier("inline-editor-loading")
        } else if model.isReady {
            VStack(alignment: .leading, spacing: 12) {
                SourcePreservingTextView(
                    text: Binding(
                        get: { model.draft },
                        set: { model.updateDraft($0) }
                    ),
                    sourceSnapshot: model.sourceSnapshot,
                    initialScrollOffset: initialScrollOffset
                )
                .frame(minHeight: 360, alignment: .topLeading)
                .accessibilityIdentifier("inline-editor-structured-surface")

                if model.isSaving {
                    Label("正在保存", systemImage: "arrow.triangle.2.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("正在保存笔记")
                }

                if let failure = model.failure {
                    InlineEditorFailureView(
                        failure: failure,
                        isDirty: model.isDirty,
                        dismiss: model.dismissFailure
                    )
                }
            }
        } else {
            ContentUnavailableView {
                Label("无法编辑笔记", systemImage: "doc.badge.exclamationmark")
            } description: {
                Text("文件可能已移动、过大或不是有效的 UTF-8 Markdown。")
            } actions: {
                Button("重试") { Task { await model.load() } }
                Button("返回阅读") {
                    retryReaderLoad()
                    finishEditing()
                }
            }
            .accessibilityIdentifier("inline-editor-error")
        }
    }
}

private struct ReaderScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InlineEditorFailureView: View {
    let failure: EditorFailure
    let isDirty: Bool
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(message)
                .font(.footnote)
            Button("知道了", action: dismiss)
                .font(.footnote)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)。\(message)")
        .accessibilityIdentifier("inline-editor-failure")
    }

    private var title: String {
        switch failure {
        case .contentChanged: "笔记已在别处修改"
        case .commitUncertain: "保存状态需要确认"
        case .indexRefreshFailed: "笔记已保存"
        case .loadFailed: "无法载入笔记"
        case .saveFailed: "无法保存笔记"
        }
    }

    private var message: String {
        switch failure {
        case .contentChanged:
            "为避免覆盖外部修改，当前草稿没有写入。请复制草稿并重新打开笔记后合并。"
        case .commitUncertain:
            "文件可能已经替换，但系统未能确认耐久性。请重新打开笔记核对，避免直接重复保存。"
        case .indexRefreshFailed:
            if isDirty {
                "已提交的版本安全写入；保存期间的新修改仍保留在编辑器中。列表索引暂未刷新。"
            } else {
                "Markdown 已安全写入，但列表索引暂未刷新。稍后手动刷新即可。"
            }
        case .loadFailed:
            "当前无法读取可编辑的原始 Markdown。"
        case .saveFailed:
            "原文件保持不变，请检查磁盘空间和文件权限后重试。"
        }
    }
}

struct ReaderBlocksView: View {
    let blocks: [MarkdownRenderBlock]

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            ReaderBlockView(block: block)
        }
    }
}

struct ReaderBlockView: View {
    let block: MarkdownRenderBlock

    @ViewBuilder
    var body: some View {
        switch block {
        case .heading(let level, let content):
            Text(ReaderAttributedText.render(content))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .textSelection(.enabled)
                .accessibilityRepresentation {
                    ReaderInlineAccessibilityView(inline: content)
                }
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(headingAccessibilityLevel(level))
        case .paragraph(let content):
            Text(ReaderAttributedText.render(content))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
                .accessibilityRepresentation {
                    ReaderInlineAccessibilityView(inline: content)
                }
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tertiary)
                    .frame(width: 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 10) {
                    ReaderBlocksView(blocks: blocks)
                }
            }
            .foregroundStyle(.secondary)
        case .unorderedList(let items):
            ReaderListView(items: items, start: nil)
        case .orderedList(let start, let items):
            ReaderListView(items: items, start: start)
        case .codeBlock(let language, let code):
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 8) {
                    if let language, !language.isEmpty {
                        Text(language.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(14)
            }
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        case .thematicBreak:
            Divider()
                .accessibilityHidden(true)
        case .fallback(let source):
            Text(source)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .largeTitle
        case 2: .title
        case 3: .title2
        default: .headline
        }
    }

    private func headingAccessibilityLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        case 5: .h5
        default: .h6
        }
    }
}

struct ReaderListView: View {
    let items: [MarkdownRenderListItem]
    let start: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .top, spacing: 10) {
                    marker(item, offset: offset)
                        .frame(minWidth: 22, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 8) {
                        ReaderBlocksView(blocks: item.blocks)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownRenderListItem, offset: Int) -> some View {
        switch item.task {
        case .checked:
            Image(systemName: "checkmark.square.fill")
                .accessibilityLabel("已完成")
        case .unchecked:
            Image(systemName: "square")
                .accessibilityLabel("未完成")
        case nil:
            if let start {
                Text("\(start + offset).")
            } else {
                Text("•")
                    .accessibilityHidden(true)
            }
        }
    }
}

enum ReaderAttributedText {
    private struct Style {
        var emphasized = false
        var strong = false
        var strikethrough = false
        var code = false
        var link: URL?
    }

    static func render(_ inline: [MarkdownRenderInline]) -> AttributedString {
        var result = AttributedString()
        append(inline, style: Style(), to: &result)
        return result
    }

    static func accessibilitySegments(
        _ inline: [MarkdownRenderInline]
    ) -> [ReaderInlineAccessibilitySegment] {
        var segments: [ReaderInlineAccessibilitySegment] = []
        appendAccessibilitySegments(inline, style: Style(), to: &segments)
        return segments
    }

    private static func appendAccessibilitySegments(
        _ inline: [MarkdownRenderInline],
        style: Style,
        to output: inout [ReaderInlineAccessibilitySegment]
    ) {
        for element in inline {
            switch element {
            case .text(let value):
                appendAccessibilitySegment(value, style: style, to: &output)
            case .emphasis(let children):
                var nested = style
                nested.emphasized = true
                appendAccessibilitySegments(children, style: nested, to: &output)
            case .strong(let children):
                var nested = style
                nested.strong = true
                appendAccessibilitySegments(children, style: nested, to: &output)
            case .strikethrough(let children):
                var nested = style
                nested.strikethrough = true
                appendAccessibilitySegments(children, style: nested, to: &output)
            case .code(let value):
                var nested = style
                nested.code = true
                appendAccessibilitySegment(value, style: nested, to: &output)
            case .link(let children, let destination):
                var nested = style
                nested.link = destination
                appendAccessibilitySegments(children, style: nested, to: &output)
            case .image(let alternativeText):
                appendAccessibilitySegment(
                    alternativeText.isEmpty ? "[图片]" : "[图片：\(alternativeText)]",
                    style: style,
                    to: &output
                )
            case .wikiLink(let label, _, let resolution):
                var nested = style
                if case .resolved(let path) = resolution {
                    nested.link = ReaderInternalRoute.url(for: path)
                }
                appendAccessibilitySegment(label, style: nested, to: &output)
            case .lineBreak:
                appendAccessibilitySegment("\n", style: style, to: &output)
            }
        }
    }

    private static func appendAccessibilitySegment(
        _ text: String,
        style: Style,
        to output: inout [ReaderInlineAccessibilitySegment]
    ) {
        guard !text.isEmpty else { return }
        if let last = output.last, last.destination == style.link {
            output[output.count - 1] = ReaderInlineAccessibilitySegment(
                label: last.label + text,
                destination: last.destination
            )
        } else {
            output.append(
                ReaderInlineAccessibilitySegment(label: text, destination: style.link)
            )
        }
    }

    private static func append(
        _ inline: [MarkdownRenderInline],
        style: Style,
        to output: inout AttributedString
    ) {
        for element in inline {
            switch element {
            case .text(let value):
                append(value, style: style, to: &output)
            case .emphasis(let children):
                var nested = style
                nested.emphasized = true
                append(children, style: nested, to: &output)
            case .strong(let children):
                var nested = style
                nested.strong = true
                append(children, style: nested, to: &output)
            case .strikethrough(let children):
                var nested = style
                nested.strikethrough = true
                append(children, style: nested, to: &output)
            case .code(let value):
                var nested = style
                nested.code = true
                append(value, style: nested, to: &output)
            case .link(let children, let destination):
                var nested = style
                nested.link = destination
                append(children, style: nested, to: &output)
            case .image(let alternativeText):
                append(
                    alternativeText.isEmpty ? "[图片]" : "[图片：\(alternativeText)]",
                    style: style,
                    to: &output
                )
            case .wikiLink(let label, _, let resolution):
                var nested = style
                if case .resolved(let path) = resolution {
                    nested.link = ReaderInternalRoute.url(for: path)
                }
                append(label, style: nested, to: &output)
            case .lineBreak:
                append("\n", style: style, to: &output)
            }
        }
    }

    private static func append(
        _ text: String,
        style: Style,
        to output: inout AttributedString
    ) {
        var segment = AttributedString(text)
        var font = Font.body
        if style.code {
            font = .system(.body, design: .monospaced)
        }
        if style.strong { font = font.bold() }
        if style.emphasized { font = font.italic() }
        segment.font = font
        if style.strikethrough { segment.strikethroughStyle = .single }
        segment.link = style.link
        output.append(segment)
    }
}

struct ReaderInlineAccessibilitySegment: Equatable, Identifiable {
    let label: String
    let destination: URL?

    var id: String {
        "\(label)|\(destination?.absoluteString ?? "")"
    }
}

private struct ReaderInlineAccessibilityView: View {
    let inline: [MarkdownRenderInline]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(
                Array(ReaderAttributedText.accessibilitySegments(inline).enumerated()), id: \.offset
            ) {
                _, segment in
                if let destination = segment.destination {
                    Link(segment.label, destination: destination)
                        .accessibilityLabel("链接：\(segment.label)")
                } else {
                    Text(segment.label)
                }
            }
        }
    }
}
