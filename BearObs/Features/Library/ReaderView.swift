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
    private let source: ReaderDataSource

    public init(model: ReaderFeatureModel) {
        _model = State(initialValue: model)
        source = model.dataSource
    }

    public init(path: VaultPath, source: ReaderDataSource) {
        _model = State(initialValue: ReaderFeatureModel(path: path, source: source))
        self.source = source
    }

    public var body: some View {
        content
            .navigationTitle(title)
            .task { await model.load() }
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
                ReaderView(path: path, source: source)
            }
    }

    @ViewBuilder
    private var content: some View {
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

    private var title: String {
        if case .content(let document) = model.state, !document.title.isEmpty {
            return document.title
        }
        return model.path.fileNameWithoutExtension
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
        case .paragraph(let content):
            Text(ReaderAttributedText.render(content))
                .font(.body)
                .lineSpacing(4)
                .textSelection(.enabled)
        case .quote(let blocks):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tertiary)
                    .frame(width: 4)
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
