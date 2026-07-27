import SwiftUI

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var foldersExpanded = true

    var body: some View {
        Group {
            if model.isWorkspaceOpen {
                List(selection: $model.sidebarSelection) {
                    librarySection
                    workspaceSection
                    savedSearchesSection
                    recentWorkspacesSection
                }
            } else {
                ContentUnavailableView {
                    Label("No Workspace", systemImage: "archivebox")
                } description: {
                    Text("Open a folder of Markdown files to browse it.")
                } actions: {
                    Button("Open Workspace…") { model.isWorkspaceImporterPresented = true }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
    }

    private var librarySection: some View {
        Section("Library") {
            Label("All Documents", systemImage: "tray.full")
                .tag(SidebarItem.allDocuments)
                .badge(model.store.documents.count)
            Label("Recent", systemImage: "clock")
                .tag(SidebarItem.recent)
            Label("Favorites", systemImage: "star")
                .tag(SidebarItem.favorites)
                .badge(model.store.favoriteDocuments.count)
        }
    }

    private var workspaceSection: some View {
        Section("Workspace") {
            Label(model.workspaceName ?? "Workspace", systemImage: "archivebox")
                .tag(SidebarItem.workspaceRoot)
            DisclosureGroup(isExpanded: $foldersExpanded) {
                OutlineGroup(model.store.folderTree, children: \.children) { folder in
                    Label(folder.name, systemImage: "folder")
                        .tag(SidebarItem.folder(folder.id))
                }
            } label: {
                Label("Folders", systemImage: "folder")
            }
        }
    }

    private var savedSearchesSection: some View {
        Section("Saved Searches") {
            ForEach(SavedSearch.allCases) { search in
                Label(search.rawValue, systemImage: search.systemImage)
                    .tag(SidebarItem.savedSearch(search))
            }
        }
    }

    @ViewBuilder
    private var recentWorkspacesSection: some View {
        let others = model.store.recentWorkspaces.filter { $0.canonicalPath != model.store.rootURL?.canonicalPath }
        if !others.isEmpty {
            Section("Recent Workspaces") {
                ForEach(others, id: \.path) { url in
                    Label(url.lastPathComponent, systemImage: "folder.badge.gearshape")
                        .tag(SidebarItem.recentWorkspace(url))
                        .help(url.path)
                }
            }
        }
    }
}
