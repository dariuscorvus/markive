import SwiftUI

struct DocumentDetailView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Group {
            if model.workspaceName == nil {
                ContentUnavailableView {
                    Label("No Workspace Open", systemImage: "archivebox")
                } description: {
                    Text("Open a workspace to browse and edit its Markdown documents.")
                } actions: {
                    Button("Open Workspace…") { model.openSampleWorkspace() }
                }
            } else if model.documentSelection.count > 1 {
                ContentUnavailableView(
                    "\(model.documentSelection.count) Documents Selected",
                    systemImage: "doc.on.doc",
                    description: Text("Select a single document to edit it.")
                )
            } else if let document = model.selectedDocument {
                DocumentContentView(model: model, document: document)
            } else {
                ContentUnavailableView {
                    Label("No Document Selected", systemImage: "doc.text")
                } description: {
                    Text("Select a document from the list, or create a new one.")
                } actions: {
                    Button("New Document") { model.newDocument() }
                }
            }
        }
        .navigationTitle(model.selectedDocument?.title ?? model.workspaceName ?? "Markive")
        .navigationSubtitle(model.selectedDocument?.path ?? "")
        .toolbar { detailToolbar }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .disabled(!model.canGoBack)
            .help("Show the previous document (⌘[)")
            Button {
                model.goForward()
            } label: {
                Label("Forward", systemImage: "chevron.forward")
            }
            .disabled(!model.canGoForward)
            .help("Show the next document in history (⌘])")
        }
        ToolbarItem {
            Button {
                model.isQuickOpenPresented = true
            } label: {
                Label("Quick Open", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(model.workspaceName == nil)
            .help("Open a document by name (⌘P)")
        }
        ToolbarItem {
            Picker("Presentation", selection: $model.presentation) {
                ForEach(DetailPresentation.allCases) { presentation in
                    Label(presentation.title, systemImage: presentation.systemImage)
                        .accessibilityLabel(presentation.title)
                        .tag(presentation)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.selectedDocument == nil)
            .help("Switch between editor and preview")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                if let id = model.selectedDocumentID {
                    model.store.toggleFavorite(id: id)
                }
            } label: {
                Label(
                    "Favorite",
                    systemImage: model.selectedDocument?.isFavorite == true ? "star.fill" : "star"
                )
            }
            .disabled(model.selectedDocument == nil)
            .help("Add or remove this document from Favorites")
            if let document = model.selectedDocument {
                ShareLink(item: document.content)
                    .help("Share the document text")
            }
            Button {
                model.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector (⌥⌘I)")
        }
    }
}

private struct DocumentContentView: View {
    @Bindable var model: WorkspaceModel
    var document: PrototypeDocument

    var body: some View {
        Group {
            switch document.status {
            case .missing:
                ContentUnavailableView(
                    "File Not Found",
                    systemImage: "questionmark.folder",
                    description: Text("“\(document.path)” was moved or deleted outside Markive.")
                )
            case .unreadable:
                ContentUnavailableView(
                    "Can't Read Document",
                    systemImage: "exclamationmark.triangle",
                    description: Text("“\(document.path)” is not valid Markdown or could not be decoded.")
                )
            case .ok, .externallyChanged:
                presentationBody
            }
        }
        .alert(
            "“\(document.title)” changed on disk",
            isPresented: externalChangeBinding
        ) {
            Button("Reload") { model.store.resolveExternalChange(id: document.id) }
            Button("Keep My Version", role: .cancel) {
                model.store.resolveExternalChange(id: document.id)
            }
        } message: {
            Text("Another application modified this file. Prototype state only — nothing is read from disk.")
        }
    }

    @ViewBuilder
    private var presentationBody: some View {
        switch model.presentation {
        case .editor:
            MarkdownEditorView(text: contentBinding)
        case .preview:
            MarkdownPreviewView(document: document)
        case .editorAndPreview:
            HSplitView {
                MarkdownEditorView(text: contentBinding)
                    .frame(minWidth: 200)
                MarkdownPreviewView(document: document)
                    .frame(minWidth: 200)
            }
        }
    }

    private var contentBinding: Binding<String> {
        Binding(
            get: { model.store.document(id: document.id)?.content ?? "" },
            set: { model.store.updateContent(id: document.id, content: $0) }
        )
    }

    private var externalChangeBinding: Binding<Bool> {
        Binding(
            get: { model.store.document(id: document.id)?.status == .externallyChanged },
            set: { if !$0 { model.store.resolveExternalChange(id: document.id) } }
        )
    }
}
