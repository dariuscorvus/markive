import SwiftUI

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var foldersExpanded = true
    @State private var tagsExpanded = true

    var body: some View {
        Group {
            if model.workspaceName == nil {
                ContentUnavailableView {
                    Label("No Workspace", systemImage: "archivebox")
                } description: {
                    Text("Open a workspace to see its folders and tags.")
                } actions: {
                    Button("Open Workspace…") { model.openSampleWorkspace() }
                }
            } else {
                List(selection: $model.sidebarSelection) {
                    librarySection
                    workspaceSection
                    locationsSection
                    savedSearchesSection
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
                .badge(model.store.favoriteCount)
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
            DisclosureGroup(isExpanded: $tagsExpanded) {
                ForEach(model.store.allTags, id: \.self) { tag in
                    Label(tag, systemImage: "number")
                        .tag(SidebarItem.tag(tag))
                }
            } label: {
                Label("Tags", systemImage: "tag")
            }
        }
    }

    private var locationsSection: some View {
        Section("Locations") {
            ForEach(DocumentLocation.allCases) { location in
                Label(location.rawValue, systemImage: location.systemImage)
                    .tag(SidebarItem.location(location))
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
}
