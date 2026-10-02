import SwiftUI

#if SWIFT_PACKAGE
    import BearObsLibrary
#endif

/// iOS app entry (REQ-004 / ADR-010). The read-only iOS client deliberately
/// has no `.commands` scene and no editing surface: the reader is constructed
/// with `editorSource == nil` everywhere in this target.
@main
struct BearObsIOSApp: App {
    @State private var workspace: AppWorkspaceModel

    init() {
        _workspace = State(initialValue: AppWorkspaceModel())
    }

    var body: some Scene {
        WindowGroup {
            IOSWorkspaceView(workspace: workspace)
        }
    }
}
