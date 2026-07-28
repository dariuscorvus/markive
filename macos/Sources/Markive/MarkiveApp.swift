import SwiftUI
import AppKit

@main
struct MarkiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Periodic autosave is off (0) by default; without it, autosave-in-place
        // only fires on events like deactivation and close.
        NSDocumentController.shared.autosavingDelay = 5
        // Route Finder "Open With" / double-click requests to the shared store
        // instead of SwiftUI's default onOpenURL, which opens a new window per URL —
        // Markive has one workspace-scoped window, not a window per document.
        appDelegate.store = store
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: WorkspaceStore?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            store?.pendingFileOpen = url
        }
    }
}
