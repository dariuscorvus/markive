import SwiftUI
import AppKit

struct DocumentListView: View {
    @Bindable var model: WorkspaceModel

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
                    // Document creation arrives with the editing layer.
                    Button {
                    } label: {
                        Label("New Document", systemImage: "square.and.pencil")
                    }
                    .disabled(true)
                    .help("Creating documents is not available yet")
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
                ContentUnavailableView(
                    "No Documents",
                    systemImage: "doc",
                    description: Text("This collection has no Markdown documents.")
                )
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
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.url.path, forType: .string)
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([document.url])
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
