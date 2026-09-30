import SwiftUI

#if SWIFT_PACKAGE
    import BearObsLibrary
#endif

@main
struct BearObsApp: App {
    @State private var workspace: AppWorkspaceModel

    init() {
        _workspace = State(initialValue: AppWorkspaceModel())
    }

    var body: some Scene {
        WindowGroup {
            ProjectShellView(workspace: workspace)
        }
        .commands {
            ReaderEditCommands()
        }
    }
}

/// 键盘入口（REQ-002 P6）：菜单命令持有 Command-E，无论当前键盘焦点在
/// 列表、正文还是工具栏都能触发当前阅读面显示的那篇笔记的“编辑”动作。
/// 阅读面进入编辑态或不存在时命令自动禁用。
private struct ReaderEditCommands: Commands {
    @FocusedValue(\.readerEditCommand)
    private var readerEditCommand: (() -> Void)?

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("编辑笔记") {
                readerEditCommand?()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(readerEditCommand == nil)
        }
    }
}
