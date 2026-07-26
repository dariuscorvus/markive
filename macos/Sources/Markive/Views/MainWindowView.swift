import SwiftUI

struct MainWindowView: View {
    @State private var model: WorkspaceModel

    init(store: PrototypeStore, configure: ((WorkspaceModel) -> Void)? = nil) {
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
        .focusedSceneValue(\.workspace, model)
    }
}

#Preview("Document selected") {
    MainWindowView(store: .sample()) { model in
        model.documentSelection = [model.store.documents[0].id]
    }
}

#Preview("No workspace open") {
    MainWindowView(store: .sample()) { model in
        model.workspaceName = nil
    }
}

#Preview("Empty collection") {
    MainWindowView(store: .sample()) { model in
        model.sidebarSelection = .location(.externalFolders)
    }
}

#Preview("Search with no results") {
    MainWindowView(store: .sample()) { model in
        model.searchText = "zzzz"
    }
}

#Preview("Inspector visible") {
    MainWindowView(store: .sample()) { model in
        model.documentSelection = [model.store.documents[0].id]
        model.isInspectorPresented = true
    }
}

#Preview("Editor and preview") {
    MainWindowView(store: .sample()) { model in
        model.documentSelection = [model.store.documents[0].id]
        model.presentation = .editorAndPreview
    }
}
