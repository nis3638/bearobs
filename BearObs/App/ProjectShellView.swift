import Observation
import SwiftUI
import UniformTypeIdentifiers

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
    import BearObsLibrary
#endif

struct ProjectShellView: View {
    @Bindable private var workspace: AppWorkspaceModel
    @State private var isImporterPresented = false

    init(workspace: AppWorkspaceModel) {
        _workspace = Bindable(workspace)
    }

    var body: some View {
        Group {
            if workspace.vaultURL == nil {
                VaultSelectionPrompt(
                    descriptionText: "BearObs 会读取你选择的本地 Markdown；只有点击保存时才会修改对应笔记。",
                    errorMessage: workspace.errorMessage,
                    openVault: { isImporterPresented = true }
                )
            } else {
                VaultWorkspaceView(environment: workspace.environment)
                    .id(workspace.environment.vaultID)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("打开 Vault…", systemImage: "folder") {
                    isImporterPresented = true
                }
                .accessibilityIdentifier("open-vault")
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            workspace.openVault(url)
        }
    }
}
