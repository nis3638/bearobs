import SwiftUI

#if SWIFT_PACKAGE
    import BearObsLibrary
#endif

@main
struct BearObsApp: App {
    var body: some Scene {
        WindowGroup {
            ProjectShellView()
        }
    }
}
