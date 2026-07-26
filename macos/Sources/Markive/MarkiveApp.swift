import SwiftUI

@main
struct MarkiveApp: App {
    /// Shared across windows; each window keeps its own navigation state.
    @State private var store = PrototypeStore.sample()

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowView(store: store)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            AppCommands()
        }
    }
}
