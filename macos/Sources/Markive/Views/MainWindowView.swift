import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @State private var model: WorkspaceModel

    init(store: WorkspaceStore, configure: ((WorkspaceModel) -> Void)? = nil) {
        let model = WorkspaceModel(store: store)
        configure?(model)
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.columnVisibility) {
            SidebarView(model: model)
        } content: {
            DocumentListView(model: model)
        } detail: {
            DocumentDetailView(model: model)
        }
        .inspector(isPresented: $model.isInspectorPresented) {
            DocumentInspectorView(model: model)
        }
        .sheet(isPresented: $model.isQuickOpenPresented) {
            QuickOpenView(model: model)
        }
        .fileImporter(
            isPresented: $model.isWorkspaceImporterPresented,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                Task { await model.store.openWorkspace(at: url) }
            }
        }
        .task {
            await model.store.restoreMostRecentWorkspace()
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
