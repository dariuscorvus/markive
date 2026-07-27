import SwiftUI
import Observation

enum SidebarItem: Hashable {
    case allDocuments
    case recent
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
    var presentation: DetailPresentation = .editor
    var sortOrder: DocumentSortOrder = .dateModified
    var searchText = ""
    var isInspectorPresented = false
    var isQuickOpenPresented = false
    var isWorkspaceImporterPresented = false
    var columnVisibility: NavigationSplitViewVisibility = .all

    var isFocusMode = false {
        didSet {
            columnVisibility = isFocusMode ? .detailOnly : .all
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

    /// Route all list-driven selection changes through here so back/forward history is recorded.
    func setDocumentSelection(_ newValue: Set<FileID>) {
        if let current = selectedDocumentID,
           newValue.count == 1, let next = newValue.first, next != current {
            backStack.append(current)
            forwardStack.removeAll()
        }
        documentSelection = newValue
    }

    /// Open the selected document through the shared session. Called whenever
    /// the selection changes.
    func loadSelectedDocument() {
        guard let item = selectedDocument else {
            openedDocument = nil
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
