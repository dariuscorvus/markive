import SwiftUI
import AppKit
import Observation

enum SidebarItem: Hashable {
    case allDocuments
    case recent
    case favorites
    case workspaceRoot
    case folder(String)
    case savedSearch(SavedSearch)
    case recentWorkspace(URL)
}

enum DetailPresentation: String, CaseIterable, Identifiable {
    case editor
    case preview
    case editorAndPreview

    var id: Self { self }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .preview: "Preview"
        case .editorAndPreview: "Editor and Preview"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: "character.cursor.ibeam"
        case .preview: "eye"
        case .editorAndPreview: "rectangle.split.2x1"
        }
    }
}

enum DocumentSortOrder: String, CaseIterable, Identifiable {
    case dateModified
    case title

    var id: Self { self }

    var label: String {
        switch self {
        case .dateModified: "Date Modified"
        case .title: "Title"
        }
    }
}

enum DocumentListStyle: String, CaseIterable, Identifiable {
    case list
    case tree

    var id: Self { self }

    var label: String {
        switch self {
        case .list: "List"
        case .tree: "Tree"
        }
    }

    var systemImage: String {
        switch self {
        case .list: "list.bullet"
        case .tree: "list.bullet.indent"
        }
    }
}

/// A node in the folder+document tree shown by `DocumentListView` in tree
/// mode — either a folder (no `document`) or a document leaf (no `children`).
struct DocumentTreeNode: Identifiable {
    var id: String
    var name: String
    var document: DocumentItem?
    var children: [DocumentTreeNode]?
}

/// The single selected document, opened through the shared NSDocument session.
struct OpenedDocument {
    enum State {
        case document(MarkdownDocument)
        case failed(DocumentLoadFailure)
    }

    var id: FileID
    var state: State

    var document: MarkdownDocument? {
        if case .document(let document) = state { return document }
        return nil
    }
}

/// Per-window navigation and selection state. Document data lives in
/// `WorkspaceStore`, which is shared across windows.
@MainActor
@Observable
final class WorkspaceModel {
    let store: WorkspaceStore

    var sidebarSelection: SidebarItem? = .allDocuments {
        didSet {
            guard sidebarSelection != oldValue else { return }
            documentSelection = []
            // Selecting a recent workspace is an action, not a filter: open it,
            // then land on All Documents. Deferred — reassigning the selection
            // inside didSet is a reentrant NSTableView update.
            if case .recentWorkspace(let url) = sidebarSelection {
                Task { @MainActor in
                    sidebarSelection = .allDocuments
                    await store.openWorkspace(at: url)
                }
            }
        }
    }

    var documentSelection: Set<FileID> = []
    var openedDocument: OpenedDocument?
    /// Set by `openStandaloneFile` when the opened file isn't in any open
    /// workspace's `store.documents` — the view falls back to this so it can
    /// render the document without requiring a workspace to be open.
    private(set) var standaloneDocument: DocumentItem?
    var presentation: DetailPresentation = .preview
    var sortOrder: DocumentSortOrder = .dateModified
    var documentListStyle: DocumentListStyle = .list
    var searchText = ""
    var isInspectorPresented = false
    var isQuickOpenPresented = false
    var isWorkspaceImporterPresented = false

    /// Drives `NavigationSplitView`'s columnVisibility. Kept as a plain `@State`
    /// in `MainWindowView` rather than here — a `NavigationSplitView` bound to an
    /// `@Observable` class property doesn't reliably pick up programmatic changes.
    var isFocusMode = false {
        didSet {
            if isFocusMode { isInspectorPresented = false }
        }
    }

    private var backStack: [FileID] = []
    private var forwardStack: [FileID] = []

    init(store: WorkspaceStore) {
        self.store = store
    }

    var isWorkspaceOpen: Bool { store.rootURL != nil }
    var workspaceName: String? { store.rootName }

    // MARK: - Selection

    var selectedDocumentID: FileID? {
        documentSelection.count == 1 ? documentSelection.first : nil
    }

    var selectedDocument: DocumentItem? {
        guard let id = selectedDocumentID else { return nil }
        return store.documents.first { $0.id == id }
    }

    /// The document to display, whether it came from the sidebar selection or
    /// a standalone Finder open with no covering workspace.
    var displayedDocument: DocumentItem? {
        selectedDocument ?? standaloneDocument
    }

    /// Route all list-driven selection changes through here so back/forward history is recorded.
    func setDocumentSelection(_ newValue: Set<FileID>) {
        if let current = selectedDocumentID,
           newValue.count == 1, let next = newValue.first, next != current {
            backStack.append(current)
            forwardStack.removeAll()
        }
        documentSelection = newValue
        standaloneDocument = nil
    }

    /// Open the selected document through the shared session. Called whenever
    /// the selection changes.
    func loadSelectedDocument() {
        guard let item = selectedDocument else {
            if standaloneDocument == nil { openedDocument = nil }
            return
        }
        do {
            let document = try store.session.document(for: item)
            openedDocument = OpenedDocument(id: item.id, state: .document(document))
        } catch {
            let failure = error as? DocumentLoadFailure ?? .unreadable
            openedDocument = OpenedDocument(id: item.id, state: .failed(failure))
        }
    }

    // MARK: - Documents for the current sidebar selection

    var sidebarTitle: String {
        switch sidebarSelection {
        case nil: workspaceName ?? "Markive"
        case .allDocuments: "All Documents"
        case .recent: "Recent"
        case .favorites: "Favorites"
        case .workspaceRoot: workspaceName ?? "Workspace"
        case .folder(let path): path.components(separatedBy: "/").last ?? path
        case .savedSearch(let search): search.rawValue
        case .recentWorkspace(let url): url.lastPathComponent
        }
    }

    private func documents(matching item: SidebarItem?) -> [DocumentItem] {
        let all = store.documents
        switch item {
        case nil, .recentWorkspace:
            return []
        case .allDocuments, .workspaceRoot:
            return all
        case .recent:
            return Array(all.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(10))
        case .favorites:
            return store.favoriteDocuments
        case .folder(let path):
            return all.filter { $0.relativeFolder == path || $0.relativeFolder.hasPrefix(path + "/") }
        case .savedSearch(.modifiedToday):
            return all.filter { Calendar.current.isDateInToday($0.modifiedAt) }
        }
    }

    var visibleDocuments: [DocumentItem] {
        var documents = documents(matching: sidebarSelection)
        if !searchText.isEmpty {
            documents = documents.filter { document in
                document.title.localizedCaseInsensitiveContains(searchText)
                    || document.relativePath.localizedCaseInsensitiveContains(searchText)
            }
        }
        if case .recent = sidebarSelection { return documents }
        switch sortOrder {
        case .dateModified:
            return documents.sorted { $0.modifiedAt > $1.modifiedAt }
        case .title:
            return documents.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    /// Recent/Favorites/Saved Searches mix documents from anywhere in the
    /// workspace — a nested tree wouldn't reflect a real folder structure
    /// there, so tree mode only applies to genuinely hierarchical scopes.
    var isHierarchicalScope: Bool {
        switch sidebarSelection {
        case .allDocuments, .workspaceRoot, .folder: true
        default: false
        }
    }

    var effectiveDocumentListStyle: DocumentListStyle {
        isHierarchicalScope ? documentListStyle : .list
    }

    /// `visibleDocuments` nested into folders, for `DocumentListView`'s tree mode.
    var documentTree: [DocumentTreeNode] {
        var roots: [DocumentTreeNode] = []
        for document in visibleDocuments {
            let components = document.relativeFolder.isEmpty
                ? [] : document.relativeFolder.components(separatedBy: "/")
            Self.insertDocument(document, components: components, into: &roots, prefix: "")
        }
        return Self.sortedTree(roots)
    }

    private static func insertDocument(
        _ document: DocumentItem,
        components: [String],
        into nodes: inout [DocumentTreeNode],
        prefix: String
    ) {
        guard let head = components.first else {
            nodes.append(DocumentTreeNode(id: "doc:\(document.relativePath)", name: document.title, document: document))
            return
        }
        let id = prefix.isEmpty ? head : "\(prefix)/\(head)"
        let rest = Array(components.dropFirst())
        if let index = nodes.firstIndex(where: { $0.id == id && $0.document == nil }) {
            var children = nodes[index].children ?? []
            insertDocument(document, components: rest, into: &children, prefix: id)
            nodes[index].children = children
        } else {
            var node = DocumentTreeNode(id: id, name: head, document: nil, children: [])
            insertDocument(document, components: rest, into: &node.children!, prefix: id)
            nodes.append(node)
        }
    }

    /// Folders first (alphabetical), then documents in their existing —
    /// already `sortOrder`-sorted — relative order.
    private static func sortedTree(_ nodes: [DocumentTreeNode]) -> [DocumentTreeNode] {
        let folders = nodes.filter { $0.document == nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { node -> DocumentTreeNode in
                var node = node
                node.children = sortedTree(node.children ?? [])
                return node
            }
        let documents = nodes.filter { $0.document != nil }
        return folders + documents
    }

    // MARK: - History

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current = selectedDocumentID { forwardStack.append(current) }
        reveal(id: previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selectedDocumentID { backStack.append(current) }
        reveal(id: next)
    }

    /// Select a document without recording history, widening the sidebar scope if needed.
    private func reveal(id: FileID) {
        if !visibleDocuments.contains(where: { $0.id == id }) {
            searchText = ""
            sidebarSelection = .allDocuments
        }
        documentSelection = [id]
    }

    func selectAdjacentDocument(offset: Int) {
        let documents = visibleDocuments
        guard !documents.isEmpty else { return }
        guard let current = selectedDocumentID,
              let index = documents.firstIndex(where: { $0.id == current }) else {
            setDocumentSelection([offset > 0 ? documents.first!.id : documents.last!.id])
            return
        }
        let next = index + offset
        guard documents.indices.contains(next) else { return }
        setDocumentSelection([documents[next].id])
    }

    // MARK: - Actions

    /// User-visible message from a failed create/rename/trash. Views alert on it.
    var lastErrorMessage: String?

    func newDocument() {
        let folder: String? = if case .folder(let path) = sidebarSelection { path } else { nil }
        do {
            let item = try store.createDocument(inFolder: folder)
            searchText = ""
            setDocumentSelection([item.id])
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func rename(_ item: DocumentItem, to newTitle: String) {
        do {
            _ = try store.rename(item, to: newTitle)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func trash(_ item: DocumentItem) {
        do {
            try store.trash(item)
            documentSelection.remove(item.id)
            backStack.removeAll { $0 == item.id }
            forwardStack.removeAll { $0 == item.id }
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func saveSelectedDocument() {
        openedDocument?.document?.save(nil)
    }

    func toggleFavoriteForSelection() {
        guard let item = selectedDocument else { return }
        store.toggleFavorite(item)
    }

    /// Open a workspace document by absolute path — preview links arrive this
    /// way because render_document resolves local targets to absolute paths.
    func openDocument(atAbsolutePath path: String) {
        let canonical = URL(fileURLWithPath: path).canonicalPath
        guard let item = store.documents.first(where: { $0.url.path == canonical }) else { return }
        open(item)
    }

    /// Opens a file handed to the app directly (Finder double-click / "Open
    /// With"), which arrives with no workspace context. Under App Sandbox, the
    /// open event only grants access to this one file — not its containing
    /// folder — so this can't scan the folder as a workspace the way a
    /// sidebar-driven open can. If a workspace covering the file happens to
    /// already be open, select it normally; otherwise render it standalone.
    func openStandaloneFile(at url: URL) async {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let item = store.documents.first(where: { $0.url.path == canonical.path }) {
            open(item)
            isFocusMode = true
            return
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: canonical.path),
              let device = attributes[.systemNumber] as? Int,
              let inode = attributes[.systemFileNumber] as? Int else { return }
        // Clear any prior sidebar selection so `loadSelectedDocument` (fired by
        // DocumentDetailView's initial onChange when focus mode swaps it in)
        // can't find a stale selected item and overwrite this one.
        documentSelection = []
        let id = FileID(device: device, inode: inode)
        let item = DocumentItem(
            id: id,
            diskID: id,
            url: canonical,
            title: canonical.deletingPathExtension().lastPathComponent,
            relativePath: canonical.lastPathComponent,
            relativeFolder: "",
            folderLabel: canonical.deletingLastPathComponent().lastPathComponent,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
            createdAt: attributes[.creationDate] as? Date ?? .distantPast
        )
        standaloneDocument = item
        do {
            let document = try store.session.document(for: item)
            openedDocument = OpenedDocument(id: item.id, state: .document(document))
        } catch {
            let failure = error as? DocumentLoadFailure ?? .unreadable
            openedDocument = OpenedDocument(id: item.id, state: .failed(failure))
        }
        isFocusMode = true
    }

    /// Escape hatch out of standalone viewing: prompts for the file's
    /// containing folder (pre-navigated there, so confirming is one click)
    /// and opens it as a full workspace. Sandbox requires this interactive
    /// grant — it can't be requested silently the way `openStandaloneFile`
    /// opens the file itself.
    func promoteStandaloneToWorkspace() {
        guard let document = standaloneDocument else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.directoryURL = document.url.deletingLastPathComponent()
        panel.prompt = "Open"
        panel.message = "Choose the folder to open as a workspace."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await store.openWorkspace(at: url)
            if let item = store.documents.first(where: { $0.url.path == document.url.path }) {
                open(item)
            }
            isFocusMode = false
        }
    }

    func open(_ document: DocumentItem) {
        setDocumentSelection([document.id])
        if !visibleDocuments.contains(where: { $0.id == document.id }) {
            searchText = ""
            sidebarSelection = .allDocuments
            documentSelection = [document.id]
        }
        isQuickOpenPresented = false
    }
}

extension WorkspaceModel: Hashable {
    nonisolated static func == (lhs: WorkspaceModel, rhs: WorkspaceModel) -> Bool {
        lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
