import SwiftUI

extension FocusedValues {
    @Entry var workspace: WorkspaceModel?
}

struct AppCommands: Commands {
    @FocusedValue(\.workspace) private var workspace
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        fileCommands
        viewCommands
        navigateCommands
    }

    // MARK: - File

    private var fileCommands: some Commands {
        Group {
            CommandGroup(replacing: .newItem) {
                Button("New Document") { workspace?.newDocument() }
                    .keyboardShortcut("n")
                    .disabled(workspace?.isWorkspaceOpen != true)
                Button("New Window") { openWindow(id: "main") }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Open Workspace…") { workspace?.isWorkspaceImporterPresented = true }
                    .keyboardShortcut("o")
                    .disabled(workspace == nil)
                Button("Quick Open…") { workspace?.isQuickOpenPresented = true }
                    .keyboardShortcut("p")
                    .disabled(workspace?.isWorkspaceOpen != true)
                Button("Search Workspace…") { workspace?.isKnowledgeSearchPresented = true }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(workspace?.isWorkspaceOpen != true)
                Divider()
                Button("Open Today's Note") { workspace?.openToday() }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(workspace?.isWorkspaceOpen != true)
                Button("New from Template…") { workspace?.isTemplatePickerPresented = true }
                    .disabled(workspace?.store.templateDocuments().isEmpty != false)
            }
            CommandGroup(replacing: .saveItem) {
                // Documents autosave in place; ⌘S commits immediately.
                Button("Save") { workspace?.saveSelectedDocument() }
                    .keyboardShortcut("s")
                    .disabled(workspace?.openedDocument?.document == nil)
            }
            // Frees ⌘P for Quick Open; printing Markdown is a later concern.
            CommandGroup(replacing: .printItem) {}
        }
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Toggle("Show Inspector", isOn: binding(\.isInspectorPresented))
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(workspace == nil)
            Divider()
            ForEach(DetailPresentation.allCases) { presentation in
                Toggle(presentation.title, isOn: presentationBinding(presentation))
                    .keyboardShortcut(presentation.shortcutKey)
                    .disabled(workspace == nil)
            }
            Divider()
            Toggle("Focus Mode", isOn: binding(\.isFocusMode))
                .disabled(workspace == nil)
        }
    }

    // MARK: - Navigate

    private var navigateCommands: some Commands {
        CommandMenu("Navigate") {
            Button("Back") { workspace?.goBack() }
                .keyboardShortcut("[")
                .disabled(workspace?.canGoBack != true)
            Button("Forward") { workspace?.goForward() }
                .keyboardShortcut("]")
                .disabled(workspace?.canGoForward != true)
            Divider()
            Button("Next Document") { workspace?.selectAdjacentDocument(offset: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(workspace?.isWorkspaceOpen != true)
            Button("Previous Document") { workspace?.selectAdjacentDocument(offset: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(workspace?.isWorkspaceOpen != true)
        }
    }

    // MARK: - Bindings

    private func binding(_ keyPath: ReferenceWritableKeyPath<WorkspaceModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { workspace?[keyPath: keyPath] ?? false },
            set: { workspace?[keyPath: keyPath] = $0 }
        )
    }

    private func presentationBinding(_ presentation: DetailPresentation) -> Binding<Bool> {
        Binding(
            get: { workspace?.presentation == presentation },
            set: { if $0 { workspace?.presentation = presentation } }
        )
    }
}

extension DetailPresentation {
    var shortcutKey: KeyEquivalent {
        switch self {
        case .editor: "1"
        case .preview: "2"
        case .editorAndPreview: "3"
        }
    }
}
