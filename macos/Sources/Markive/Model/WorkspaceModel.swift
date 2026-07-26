import SwiftUI
import Observation

enum SidebarItem: Hashable {
    case allDocuments
    case recent
    case favorites
    case workspaceRoot
    case folder(String)
    case tag(String)
    case location(DocumentLocation)
    case savedSearch(SavedSearch)
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

/// Per-window navigation and selection state. Document data lives in `PrototypeStore`,
/// which is shared across windows.
@MainActor
@Observable
final class WorkspaceModel {
    let store: PrototypeStore
    var workspaceName: String?

    var sidebarSelection: SidebarItem? = .allDocuments {
        didSet {
            if sidebarSelection != oldValue { documentSelection = [] }
        }
    }

    var documentSelection: Set<PrototypeDocument.ID> = []
    var presentation: DetailPresentation = .editor
    var sortOrder: DocumentSortOrder = .dateModified
    var searchText = ""
    var isInspectorPresented = false
    var isQuickOpenPresented = false
    var columnVisibility: NavigationSplitViewVisibility = .all

    var isFocusMode = false {
        didSet {
            columnVisibility = isFocusMode ? .detailOnly : .all
            if isFocusMode { isInspectorPresented = false }
        }
    }

    private var backStack: [PrototypeDocument.ID] = []
    private var forwardStack: [PrototypeDocument.ID] = []

    init(store: PrototypeStore, workspaceName: String? = "Markive Vault") {
        self.store = store
        self.workspaceName = workspaceName
    }

    // MARK: - Selection

    var selectedDocumentID: PrototypeDocument.ID? {
        documentSelection.count == 1 ? documentSelection.first : nil
    }

    var selectedDocument: PrototypeDocument? {
        selectedDocumentID.flatMap { store.document(id: $0) }
    }

    /// Route all list-driven selection changes through here so back/forward history is recorded.
    func setDocumentSelection(_ newValue: Set<PrototypeDocument.ID>) {
        if let current = selectedDocumentID,
           newValue.count == 1, let next = newValue.first, next != current {
            backStack.append(current)
            forwardStack.removeAll()
        }
        documentSelection = newValue
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
        case .tag(let tag): "#\(tag)"
        case .location(let location): location.rawValue
        case .savedSearch(let search): search.rawValue
        }
    }

    private func documents(matching item: SidebarItem?) -> [PrototypeDocument] {
        let all = store.documents
        switch item {
        case nil:
            return []
        case .allDocuments, .workspaceRoot:
            return all
        case .recent:
            return Array(all.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(10))
        case .favorites:
            return all.filter(\.isFavorite)
        case .folder(let path):
            return all.filter { $0.folder == path || $0.folder.hasPrefix(path + "/") }
        case .tag(let tag):
            return all.filter { $0.tags.contains(tag) }
        case .location(let location):
            return all.filter { $0.location == location }
        case .savedSearch(.modifiedToday):
            return all.filter { Calendar.current.isDateInToday($0.modifiedAt) }
        case .savedSearch(.unlinkedNotes):
            return all.filter(\.isUnlinked)
        }
    }

    var visibleDocuments: [PrototypeDocument] {
        var documents = documents(matching: sidebarSelection)
        if !searchText.isEmpty {
            documents = documents.filter { document in
                document.title.localizedCaseInsensitiveContains(searchText)
                    || document.path.localizedCaseInsensitiveContains(searchText)
                    || document.content.localizedCaseInsensitiveContains(searchText)
                    || document.tags.contains { $0.localizedCaseInsensitiveContains(searchText) }
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
    private func reveal(id: PrototypeDocument.ID) {
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

    func newDocument() {
        let document = store.createDocument()
        searchText = ""
        sidebarSelection = .allDocuments
        setDocumentSelection([document.id])
    }

    func open(_ document: PrototypeDocument) {
        setDocumentSelection([document.id])
        if !visibleDocuments.contains(where: { $0.id == document.id }) {
            searchText = ""
            sidebarSelection = .allDocuments
            documentSelection = [document.id]
        }
        isQuickOpenPresented = false
    }

    func openSampleWorkspace() {
        workspaceName = "Markive Vault"
        sidebarSelection = .allDocuments
    }

    func remove(_ document: PrototypeDocument) {
        store.remove(id: document.id)
        documentSelection.remove(document.id)
        backStack.removeAll { $0 == document.id }
        forwardStack.removeAll { $0 == document.id }
    }

    func saveSelectedDocument() {
        guard let id = selectedDocumentID else { return }
        store.touch(id: id)
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
