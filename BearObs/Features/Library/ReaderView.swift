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

/// Command-E entry for the edit action of the reader currently on screen
/// (REQ-002 P6). The reader publishes the closure through
/// `focusedSceneValue` while it shows the reading surface; the app's menu
/// command owns the shortcut so it fires no matter what holds key focus.
private struct ReaderEditCommandKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    public var readerEditCommand: (() -> Void)? {
        get { self[ReaderEditCommandKey.self] }
        set { self[ReaderEditCommandKey.self] = newValue }
    }
}

/// Layout metrics shared by the reader and the inline editor so both states of
/// the detail column present the same content column (REQ-002 5.3). Defined in
/// this shared file because the read path consumes it on every platform; the
/// Mac-only editor surface (ReaderInlineEditor.swift) consumes the editor
/// tokens (platform seams are recorded in REQ-004 §7 / ADR-010).
enum ReaderEditorLayoutToken {
    static let contentMaxWidth: CGFloat = 760
    static let contentHorizontalPadding: CGFloat = 20
    static let contentVerticalPadding: CGFloat = 24
    /// Text column width inside the editor surface once the shared horizontal
    /// padding is subtracted from the reader content width.
    static let editorTextColumnWidth = contentMaxWidth - contentHorizontalPadding * 2
}

public struct ReaderView: View {
    @State private var model: ReaderFeatureModel
    @State private var destination: VaultPath?
    @State private var editorModel: EditorFeatureModel?
    @State private var isDiscardConfirmationPresented = false
    /// Continuously tracked reader viewport in source coordinates; frozen
    /// when the user enters edit mode (REQ-002 6.1).
    @State private var readerViewport: ReaderViewportSnapshot?
    /// The viewport frozen for the active editing session.
    @State private var editorViewportRestore: ReaderViewportSnapshot?
    /// Where the reader should reposition itself when the editing session
    /// ends, expressed as a top-level block index in the rendered document.
    @State private var pendingRestoreBlockIndex: Int?
    @State private var scrollPosition = ScrollPosition()
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
            .focusedSceneValue(\.readerEditCommand, editCommand)
            .task(id: requestedPath) {
                if model.path != requestedPath {
                    editorModel = nil
                    isDiscardConfirmationPresented = false
                    destination = nil
                    // A new note must not inherit the old session's position
                    // state (REQ-002 P5).
                    readerViewport = nil
                    editorViewportRestore = nil
                    pendingRestoreBlockIndex = nil
                    scrollPosition = ScrollPosition()
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
                #if os(macOS)
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
                            .accessibilityHint("在原位编辑这篇笔记，快捷键 Command-E")
                            .accessibilityIdentifier("reader-edit-button")
                        }
                    }
                #endif
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
            #if os(macOS)
                .confirmationDialog(
                    "放弃未保存的修改？",
                    isPresented: $isDiscardConfirmationPresented
                ) {
                    Button("放弃修改", role: .destructive) {
                        if let editorModel {
                            prepareReaderRestore(from: editorModel)
                        }
                        editorModel = nil
                    }
                    Button("继续编辑", role: .cancel) {}
                } message: {
                    Text("这篇笔记的本地草稿尚未保存。")
                }
            #endif
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
        #if os(macOS)
            if let editorModel {
                InlineMarkdownEditor(
                    model: editorModel,
                    initialViewport: editorViewportRestore,
                    finishEditing: finishEditing,
                    retryReaderLoad: { Task { await model.load() } },
                    save: { Task { await saveEditing() } }
                )
            } else {
                readerState
            }
        #else
            readerState
        #endif
    }

    @ViewBuilder
    private var readerState: some View {
        switch model.state {
        case .loading:
            ProgressView("正在打开笔记")
                .accessibilityIdentifier("reader-loading")
        case .content(let document):
            readerContent(document)
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

    /// The reading surface. Every top-level block is anchored so the tracker
    /// can keep recording the viewport in source coordinates; a pending
    /// restore target from a finished editing session positions the scroll
    /// on first layout (REQ-002 6.1/6.4).
    private func readerContent(_ document: MarkdownRenderDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ReaderDocumentBlocksView(entries: document.entries)
            }
            .frame(
                maxWidth: ReaderEditorLayoutToken.contentMaxWidth,
                alignment: .leading
            )
            .padding(.horizontal, ReaderEditorLayoutToken.contentHorizontalPadding)
            .padding(.vertical, ReaderEditorLayoutToken.contentVerticalPadding)
            .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .coordinateSpace(name: ReaderViewportTracker.scrollCoordinateSpace)
        .onPreferenceChange(ReaderBlockFramesPreferenceKey.self) { frames in
            readerViewport = ReaderViewportTracker.snapshot(
                frames: frames,
                entries: document.entries,
                path: requestedPath
            )
        }
        .onAppear {
            guard let index = pendingRestoreBlockIndex else { return }
            scrollPosition = ScrollPosition(id: index, anchor: .top)
            pendingRestoreBlockIndex = nil
        }
        .accessibilityIdentifier("reader-content")
    }

    private var title: String {
        if case .content(let document) = model.state, !document.title.isEmpty {
            return document.title
        }
        return requestedPath.fileNameWithoutExtension
    }

    /// Keyboard entry for the edit action (REQ-002 P6): published only while
    /// the reading surface is up, so the menu command targets the reader the
    /// user actually sees.
    private var editCommand: (() -> Void)? {
        guard editorModel == nil, let editorSource else { return nil }
        return { beginEditing(with: editorSource) }
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
        // Freeze the continuously tracked viewport for this session; a stale
        // snapshot from another note must never steer the new one.
        let frozenViewport =
            readerViewport?.path == requestedPath ? readerViewport : nil
        editorViewportRestore = frozenViewport
        editorModel = EditorFeatureModel(path: requestedPath, source: source)
    }

    private func finishEditing() {
        guard let editorModel, !editorModel.isSaving else { return }
        if editorModel.isDirty {
            isDiscardConfirmationPresented = true
        } else {
            prepareReaderRestore(from: editorModel)
            self.editorModel = nil
        }
    }

    /// Editor → reader continuity: translate the editor's viewport anchor
    /// into original-file bytes and resolve it to a rendered block, so
    /// returning to reading shows the content the user was just editing
    /// near (REQ-002 P5).
    private func prepareReaderRestore(from editorModel: EditorFeatureModel) {
        editorViewportRestore = nil
        guard let sourceOffset = editorModel.readerRestoreSourceOffset else {
            pendingRestoreBlockIndex = nil
            return
        }
        guard case .content(let document) = model.state else {
            pendingRestoreBlockIndex = nil
            return
        }
        guard
            let index = ReaderViewportTracker.entryIndex(
                containing: sourceOffset,
                in: document.entries
            )
        else {
            pendingRestoreBlockIndex = nil
            return
        }
        pendingRestoreBlockIndex = index
        scrollPosition = ScrollPosition(id: index, anchor: .top)
    }

    private func saveEditing() async {
        guard let editorModel else { return }
        await editorModel.save()
        guard editorModel.failure == nil, !editorModel.isDirty else { return }
        await model.load()
    }
}

/// Top-level rendered blocks with viewport anchors: each block reports its
/// frame to the tracker so the reader can freeze its position in source
/// coordinates. Nested blocks recurse through `ReaderBlocksView` unanchored.
struct ReaderDocumentBlocksView: View {
    let entries: [MarkdownRenderBlockEntry]

    var body: some View {
        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
            ReaderBlockAnchorView(entryIndex: index) {
                ReaderBlockView(block: entry.block)
            }
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
