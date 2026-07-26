import SwiftUI
import AppKit

struct DocumentListView: View {
    @Bindable var model: WorkspaceModel
    @State private var documentPendingTrash: PrototypeDocument?

    var body: some View {
        Group {
            if model.workspaceName == nil {
                ContentUnavailableView(
                    "No Workspace",
                    systemImage: "archivebox",
                    description: Text("Open a workspace to browse its documents.")
                )
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
            } else {
                documentList
            }
        }
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
                .disabled(model.workspaceName == nil)
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
        .confirmationDialog(
            "Move “\(documentPendingTrash?.title ?? "")” to the Trash?",
            isPresented: Binding(
                get: { documentPendingTrash != nil },
                set: { if !$0 { documentPendingTrash = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let document = documentPendingTrash { model.remove(document) }
                documentPendingTrash = nil
            }
            Button("Cancel", role: .cancel) { documentPendingTrash = nil }
        } message: {
            Text("The document is removed from the prototype's in-memory store only.")
        }
    }

    private var documentList: some View {
        List(selection: selectionBinding) {
            ForEach(model.visibleDocuments) { document in
                DocumentRow(document: document)
                    .tag(document.id)
                    .draggable(document.path)
                    .contextMenu {
                        Button(document.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            model.store.toggleFavorite(id: document.id)
                        }
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(document.path, forType: .string)
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) {
                            documentPendingTrash = document
                        }
                    }
            }
        }
    }

    private var selectionBinding: Binding<Set<PrototypeDocument.ID>> {
        Binding(
            get: { model.documentSelection },
            set: { model.setDocumentSelection($0) }
        )
    }
}

struct DocumentRow: View {
    var document: PrototypeDocument

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(document.title)
                    if document.status != .ok {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .imageScale(.small)
                            .accessibilityLabel("Needs attention")
                    }
                }
                Text("\(document.folder) · \(document.modifiedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !document.tags.isEmpty {
                    Text(document.tags.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if document.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .imageScale(.small)
                    .accessibilityLabel("Favorite")
            }
        }
        .padding(.vertical, 2)
    }
}
