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
    }
}
