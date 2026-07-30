import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @State private var model: WorkspaceModel
    // Bound to NavigationSplitView directly as @State: a binding sourced from
    // an @Observable class property doesn't reliably drive its column collapse.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(store: WorkspaceStore, configure: ((WorkspaceModel) -> Void)? = nil) {
        let model = WorkspaceModel(store: store)
        configure?(model)
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        Group {
            // NavigationSplitView's columnVisibility binding doesn't reliably
            // collapse the sidebar+content columns together when set from code
            // (only a real drag or the system sidebar toggle does) — so focus
            // mode swaps to the detail view directly instead of fighting it.
            if model.isFocusMode {
                DocumentDetailView(model: model)
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(model: model)
                } content: {
                    DocumentListView(model: model)
                } detail: {
                    DocumentDetailView(model: model)
                }
            }
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            DocumentInspectorView(model: model)
        }
        .sheet(isPresented: $model.isQuickOpenPresented) {
            QuickOpenView(model: model)
        }
        .sheet(isPresented: $model.isKnowledgeSearchPresented) {
            KnowledgeSearchView(model: model)
        }
        .sheet(isPresented: $model.isTemplatePickerPresented) {
            TemplatePickerView(model: model)
        }
        .fileImporter(
            isPresented: $model.isWorkspaceImporterPresented,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                Task {
                    await model.store.openWorkspace(at: url)
                    model.openHome()
                }
            }
        }
        .task {
            await model.store.restoreMostRecentWorkspace()
            if model.selectedDocument == nil {
                model.openHome()
            }
        }
        .onChange(of: model.store.pendingFileOpen, initial: true) {
            guard let url = model.store.pendingFileOpen else { return }
            Task {
                await model.openStandaloneFile(at: url)
                model.store.pendingFileOpen = nil
            }
        }
        .alert(
            model.lastErrorMessage ?? "",
            isPresented: Binding(
                get: { model.lastErrorMessage != nil },
                set: { if !$0 { model.lastErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.lastErrorMessage = nil }
        }
        .focusedSceneValue(\.workspace, model)
    }
}

#Preview("Fixture workspace") {
    let store = WorkspaceStore(defaults: PreviewFixtures.defaults())
    MainWindowView(store: store)
        .task { await store.openWorkspace(at: PreviewFixtures.workspaceURL()) }
}

#Preview("No workspace open") {
    MainWindowView(store: WorkspaceStore(defaults: PreviewFixtures.defaults()))
}

#Preview("Inspector visible") {
    let store = WorkspaceStore(defaults: PreviewFixtures.defaults())
    MainWindowView(store: store) { model in
        model.isInspectorPresented = true
    }
    .task { await store.openWorkspace(at: PreviewFixtures.workspaceURL()) }
}

#Preview("Search with no results") {
    let store = WorkspaceStore(defaults: PreviewFixtures.defaults())
    MainWindowView(store: store) { model in
        model.searchText = "zzzz"
    }
    .task { await store.openWorkspace(at: PreviewFixtures.workspaceURL()) }
}
