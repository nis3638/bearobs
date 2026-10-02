// Mac-only inline editing surface (REQ-004 §7 / ADR-010): the Xcode iOS App
// target excludes this file outright, and the whole-file guard keeps the
// shared SPM target buildable on both platforms (empty file on iOS). The iOS
// reader is constructed with `editorSource == nil` and never enters an
// editing session.
#if os(macOS)
    import SwiftUI

    /// Mac-only inline editing surface of the detail column (REQ-002 5.2).
    ///
    /// The AppKit surface owns all scrolling; the loading, saving and failure
    /// states stay in SwiftUI around it without introducing a second editor or a
    /// second save path.
    struct InlineMarkdownEditor: View {
        let model: EditorFeatureModel
        let initialViewport: ReaderViewportSnapshot?
        let finishEditing: () -> Void
        let retryReaderLoad: () -> Void
        let save: () -> Void

        init(
            model: EditorFeatureModel,
            initialViewport: ReaderViewportSnapshot? = nil,
            finishEditing: @escaping () -> Void,
            retryReaderLoad: @escaping () -> Void,
            save: @escaping () -> Void
        ) {
            self.model = model
            self.initialViewport = initialViewport
            self.finishEditing = finishEditing
            self.retryReaderLoad = retryReaderLoad
            self.save = save
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task {
                if model.state == .idle { await model.load() }
            }
            .accessibilityIdentifier("inline-markdown-editor")
        }

        @ViewBuilder
        private var content: some View {
            if model.isLoading {
                ProgressView("正在载入原始 Markdown")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("inline-editor-loading")
            } else if model.isReady {
                editorSurface
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

        private var editorSurface: some View {
            VStack(alignment: .leading, spacing: 0) {
                SourcePreservingTextView(
                    text: model.draft,
                    revision: model.draftRevision,
                    projection: model.projectionEngine.projection,
                    sourceSnapshot: model.sourceSnapshot,
                    initialViewport: initialViewport,
                    saveStatus: EditorSaveStatus(
                        isSaving: model.isSaving,
                        failureText: model.failure.map { failure in
                            "\(failure.title)。\(failure.message(isDirty: model.isDirty))"
                        }
                    ),
                    onDraftChange: model.updateDraft,
                    onSelectionChange: { anchor, head in
                        model.updateSelection(anchorUTF8: anchor, headUTF8: head)
                    },
                    onViewportChange: { anchor, offset in
                        model.updateViewport(utf8Anchor: anchor, verticalOffset: offset)
                    },
                    onMarkedTextChange: model.setMarkedTextActive,
                    onSave: save,
                    onEscape: finishEditing
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("inline-editor-structured-surface")

                if hasStatusContent {
                    statusStrip
                }
            }
        }

        private var hasStatusContent: Bool {
            model.isSaving || model.failure != nil
        }

        private var statusStrip: some View {
            VStack(alignment: .leading, spacing: 6) {
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
                        retry: failure == .saveFailed ? save : nil,
                        dismiss: model.dismissFailure
                    )
                }
            }
            .padding(.horizontal, ReaderEditorLayoutToken.contentHorizontalPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    extension EditorFailure {
        /// User-facing titles shared by the failure strip and the VoiceOver
        /// announcements so both surfaces read the same words (REQ-002 P6).
        var title: String {
            switch self {
            case .contentChanged: "笔记已在别处修改"
            case .commitUncertain: "保存状态需要确认"
            case .indexRefreshFailed: "笔记已保存"
            case .loadFailed: "无法载入笔记"
            case .saveFailed: "无法保存笔记"
            }
        }

        func message(isDirty: Bool) -> String {
            switch self {
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

    private struct InlineEditorFailureView: View {
        let failure: EditorFailure
        let isDirty: Bool
        let retry: (() -> Void)?
        let dismiss: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Label(failure.title, systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    // The headline doubles as the queryable failure element;
                    // message and buttons stay separate so VoiceOver users can
                    // reach the actions (REQ-002 P6).
                    .accessibilityIdentifier("inline-editor-failure")
                Text(failure.message(isDirty: isDirty))
                    .font(.footnote)
                HStack(spacing: 12) {
                    if failure == .saveFailed, let retry {
                        Button("重试保存", action: retry)
                            .font(.footnote)
                            .accessibilityIdentifier("inline-editor-retry-button")
                    }
                    Button("知道了", action: dismiss)
                        .font(.footnote)
                }
            }
            .padding(.vertical, 10)
        }
    }

#endif
