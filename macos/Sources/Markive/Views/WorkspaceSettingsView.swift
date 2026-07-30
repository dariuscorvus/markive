import SwiftUI

struct WorkspaceSettingsView: View {
    @Bindable var store: WorkspaceStore

    var body: some View {
        Form {
            if store.rootURL == nil {
                ContentUnavailableView(
                    "No Workspace Open",
                    systemImage: "folder",
                    description: Text("Open a workspace before changing its note settings.")
                )
            } else {
                Section("Capture") {
                    TextField("Default folder", text: setting(\.defaultFolder))
                        .help("Relative to the workspace root. Leave empty to use the selected folder.")
                    TextField("Templates folder", text: setting(\.templatesFolder))
                }
                Section("Daily Notes") {
                    TextField("Folder", text: setting(\.dailyFolder))
                    TextField("Date format", text: setting(\.dailyFormat))
                    TextField("Template", text: setting(\.dailyTemplate))
                }
                Section("Workspace") {
                    TextField("Home note", text: setting(\.homeNote))
                    Toggle("Use wikilinks for new links", isOn: setting(\.useWikilinks))
                    Toggle("Update links when renaming notes", isOn: setting(\.alwaysUpdateLinks))
                }
                if let rootURL = store.rootURL {
                    Section("Location") {
                        Text(rootURL.path)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 460)
    }

    private func setting<Value>(
        _ keyPath: WritableKeyPath<WorkspaceSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: {
                store.settings[keyPath: keyPath] = $0
                store.saveSettings()
            }
        )
    }
}
