import SwiftUI

#if SWIFT_PACKAGE
    import BearObsIndex
#endif

public struct LibraryView: View {
    @State private var model: LibraryFeatureModel
    private let readerSource: ReaderDataSource

    public init(model: LibraryFeatureModel, readerSource: ReaderDataSource = .unavailable) {
        _model = State(initialValue: model)
        self.readerSource = readerSource
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
            ContentUnavailableView(
                "还没有笔记",
                systemImage: "doc.text",
                description: Text("首次同步完成后，笔记会出现在这里。")
            )
            .accessibilityIdentifier("library-empty")
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
                        ReaderView(path: note.path, source: readerSource)
                    } label: {
                        LibraryNoteRow(note: note)
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
            .accessibilityElement(children: .combine)
        }
    }
}

struct LibraryNoteRow: View {
    let note: IndexedNoteSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(statusColor)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(note.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(note.modifiedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if note.parseStatus != .complete {
                    Label(note.parseStatus.label, systemImage: note.parseStatus.symbolName)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch note.parseStatus {
        case .complete: .accentColor
        case .degraded: .orange
        case .failed: .red
        }
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
