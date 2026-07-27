import SwiftUI
import AppKit

struct DocumentListView: View {
    @Bindable var model: WorkspaceModel
    @State private var documentPendingTrash: DocumentItem?
    @State private var renameTarget: DocumentItem?
    @State private var renameTitle = ""

    var body: some View {
        // The List must stay in the hierarchy permanently: swapping it out for an
        // empty-state view re-hosts the toolbar search field and detaches it from
        // its binding on macOS. Empty states render as an overlay instead.
        documentList
            .overlay { emptyStateOverlay }
            .navigationTitle(model.sidebarTitle)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            .searchable(text: $model.searchText, prompt: "Search documents")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.newDocument()
                    } label: {
                        Label("New Document", systemImage: "square.and.pencil")
                    }
                    .disabled(!model.isWorkspaceOpen)
                    .help("Create a new Markdown document (⌘N)")
                }
                ToolbarItem {
                    Menu {
                        Picker("Sort By", selection: $model.sortOrder) {
                            ForEach(DocumentSortOrder.allCases) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Change how documents are sorted")
                }
            }
            .alert(
                "Rename “\(renameTarget?.title ?? "")”",
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                TextField("Title", text: $renameTitle)
                Button("Rename") {
                    if let target = renameTarget { model.rename(target, to: renameTitle) }
                    renameTarget = nil
                }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog(
                "Move “\(documentPendingTrash?.title ?? "")” to the Trash?",
                isPresented: Binding(
                    get: { documentPendingTrash != nil },
                    set: { if !$0 { documentPendingTrash = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) {
                    if let document = documentPendingTrash { model.trash(document) }
                    documentPendingTrash = nil
                }
                Button("Cancel", role: .cancel) { documentPendingTrash = nil }
            }
    }

    @ViewBuilder
    private var emptyStateOverlay: some View {
        if !model.isWorkspaceOpen {
            ContentUnavailableView {
                Label("No Workspace", systemImage: "archivebox")
            } description: {
                Text("Open a folder of Markdown files to browse it.")
            } actions: {
                Button("Open Workspace…") { model.isWorkspaceImporterPresented = true }
            }
        } else if model.store.isLoading && model.store.documents.isEmpty {
            ProgressView()
        } else if model.visibleDocuments.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Documents", systemImage: "doc")
                } description: {
                    Text("This collection has no Markdown documents.")
                } actions: {
                    Button("Create Document") { model.newDocument() }
                }
            } else {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }

    private var documentList: some View {
        List(selection: selectionBinding) {
            ForEach(model.visibleDocuments) { document in
                DocumentRow(document: document)
                    .tag(document.id)
                    .draggable(document.url)
                    .contextMenu {
                        Button("Rename…") {
                            renameTitle = document.title
                            renameTarget = document
                        }
                        Divider()
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.url.path, forType: .string)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([document.url])
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) {
                            documentPendingTrash = document
                        }
                    }
            }
        }
    }

    private var selectionBinding: Binding<Set<FileID>> {
        Binding(
            get: { model.documentSelection },
            set: { model.setDocumentSelection($0) }
        )
    }
}

struct DocumentRow: View {
    var document: DocumentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(document.title)
            Text("\(document.folderLabel) · \(document.modifiedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
