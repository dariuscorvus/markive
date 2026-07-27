import SwiftUI
import AppKit

@main
struct MarkiveApp: App {
    init() {
        // Periodic autosave is off (0) by default; without it, autosave-in-place
        // only fires on events like deactivation and close.
        NSDocumentController.shared.autosavingDelay = 5
    }

    /// Shared across windows; each window keeps its own navigation state.
    @State private var store = MarkiveApp.makeStore()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView(store: store)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            AppCommands()
        }
    }

    /// `--workspace <path>` opens a workspace at launch instead of restoring the
    /// most recent one — for development and headless verification.
    private static func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore()
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--workspace"),
           arguments.indices.contains(flag + 1) {
            let url = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
            Task { await store.openWorkspace(at: url) }
        }
        return store
    }
}
