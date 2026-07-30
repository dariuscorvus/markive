import SwiftUI

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var foldersExpanded = true
    @State private var isCreateFolderPresented = false
    @State private var createFolderParent: String?
    @State private var folderName = ""
    @State private var renameFolderPath: String?
    @State private var renamedFolderName = ""

    var body: some View {
        Group {
            if model.isWorkspaceOpen {
                List(selection: $model.sidebarSelection) {
                    librarySection
                    workspaceSection
                    tagsSection
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
        .alert("New Folder", isPresented: $isCreateFolderPresented) {
            TextField("Name", text: $folderName)
            Button("Create") {
                model.createFolder(named: folderName, in: createFolderParent)
                folderName = ""
                createFolderParent = nil
            }
            Button("Cancel", role: .cancel) {
                folderName = ""
                createFolderParent = nil
            }
        } message: {
            Text("Create a folder in \(createFolderParent ?? model.workspaceName ?? "the workspace").")
        }
        .alert(
            "Rename Folder",
            isPresented: Binding(
                get: { renameFolderPath != nil },
                set: { if !$0 { renameFolderPath = nil } }
            )
        ) {
            TextField("Name", text: $renamedFolderName)
            Button("Rename") {
                if let path = renameFolderPath {
                    model.renameFolder(relativePath: path, to: renamedFolderName)
                }
                renameFolderPath = nil
            }
            Button("Cancel", role: .cancel) { renameFolderPath = nil }
        }
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
            Button {
                model.openToday()
            } label: {
                Label("Today", systemImage: "calendar")
            }
            .buttonStyle(.plain)
            if !model.store.settings.homeNote.isEmpty {
                Button {
                    model.openHome()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .buttonStyle(.plain)
            }
            if !model.store.settings.defaultFolder.isEmpty {
                Label("Inbox", systemImage: "tray.and.arrow.down")
                    .tag(SidebarItem.folder(model.store.settings.defaultFolder))
            }
        }
    }

    @ViewBuilder
    private var tagsSection: some View {
        if !model.store.knowledgeIndex.allTags.isEmpty {
            Section("Tags") {
                ForEach(model.store.knowledgeIndex.allTags, id: \.self) { tag in
                    Label(tag, systemImage: "tag")
                        .tag(SidebarItem.tag(tag))
                }
            }
        }
    }

    private var workspaceSection: some View {
        Section("Workspace") {
            Label(model.workspaceName ?? "Workspace", systemImage: "archivebox")
                .tag(SidebarItem.workspaceRoot)
                .dropDestination(for: URL.self) { urls, _ in
                    model.moveDocuments(at: urls, toFolder: "")
                }
                .contextMenu {
                    Button("New Folder…") { presentNewFolder(in: nil) }
                }
            DisclosureGroup(isExpanded: $foldersExpanded) {
                OutlineGroup(model.store.folderTree, children: \.children) { folder in
                    folderRow(folder)
                }
            } label: {
                Label("Folders", systemImage: "folder")
            }
        }
    }

    private func folderRow(_ folder: FolderNode) -> some View {
        Label(folder.name, systemImage: "folder")
            .tag(SidebarItem.folder(folder.id))
            .dropDestination(for: URL.self) { urls, _ in
                model.moveDocuments(at: urls, toFolder: folder.id)
            }
            .contextMenu {
                Button("New Folder…") { presentNewFolder(in: folder.id) }
                Button("Rename…") {
                    renamedFolderName = folder.name
                    renameFolderPath = folder.id
                }
            }
    }

    private func presentNewFolder(in parent: String?) {
        createFolderParent = parent
        folderName = ""
        isCreateFolderPresented = true
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
                    VStack(alignment: .leading, spacing: 2) {
                        Label(url.lastPathComponent, systemImage: "folder.badge.gearshape")
                        Text(url.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                        .tag(SidebarItem.recentWorkspace(url))
                        .help(url.path)
                }
            }
        }
    }
}
