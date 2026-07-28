import SwiftUI

struct DocumentDetailView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        content
            .onChange(of: model.selectedDocumentID, initial: true) {
                model.loadSelectedDocument()
            }
            .navigationTitle(model.displayedDocument?.title ?? model.workspaceName ?? "Markive")
            .navigationSubtitle(model.displayedDocument?.relativePath ?? "")
            .toolbar { detailToolbar }
    }

    @ViewBuilder
    private var content: some View {
        if model.documentSelection.count > 1 {
            ContentUnavailableView(
                "\(model.documentSelection.count) Documents Selected",
                systemImage: "doc.on.doc",
                description: Text("Select a single document to read it.")
            )
        } else if let document = model.displayedDocument {
            DocumentContentView(model: model, document: document)
        } else if !model.isWorkspaceOpen {
            ContentUnavailableView {
                Label("No Workspace Open", systemImage: "archivebox")
            } description: {
                Text("Open a folder of Markdown files to browse and read them.")
            } actions: {
                Button("Open Workspace…") { model.isWorkspaceImporterPresented = true }
            }
        } else {
            ContentUnavailableView(
                "No Document Selected",
                systemImage: "doc.text",
                description: Text("Select a document from the list.")
            )
        }
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
            .disabled(!model.isWorkspaceOpen)
            .help("Open a document by name (⌘P)")
        }
        if model.standaloneDocument != nil {
            ToolbarItem {
                Button {
                    model.promoteStandaloneToWorkspace()
                } label: {
                    Label("Open Folder as Workspace", systemImage: "folder.badge.plus")
                }
                .help("Browse the folder this file is in")
            }
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
            .disabled(model.displayedDocument == nil)
            .help("Switch between source and preview")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.toggleFavoriteForSelection()
            } label: {
                Label(
                    "Favorite",
                    systemImage: model.selectedDocument.map { model.store.isFavorite($0) } == true
                        ? "star.fill" : "star"
                )
            }
            .disabled(model.selectedDocument == nil)
            .help("Add or remove this document from Favorites")
            // Unconditional so the toolbar structure never rebuilds mid-typing:
            // conditional toolbar content re-hosts the search field and can
            // detach it from its binding, like the List/empty-state swap did.
            // Shares the file itself — sharing the text would copy the whole
            // buffer on every body evaluation, which 20 MB documents punish.
            ShareLink(item: model.displayedDocument?.url ?? URL(fileURLWithPath: "/dev/null"))
                .disabled(model.displayedDocument == nil)
                .help("Share the document")
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
    var document: DocumentItem

    var body: some View {
        Group {
            content
        }
        .alert(
            "“\(document.title)” changed on disk",
            isPresented: conflictBinding
        ) {
            Button("Reload") {
                model.openedDocument?.document?.resolveConflictReloading()
            }
            Button("Keep My Version", role: .cancel) {
                model.openedDocument?.document?.resolveConflictKeepingLocal()
            }
        } message: {
            Text("Another application modified this file while you have unsaved edits. Reload discards your edits; Keep My Version overwrites the file.")
        }
    }

    private var conflictBinding: Binding<Bool> {
        Binding(
            get: { model.openedDocument?.document?.buffer.hasConflict ?? false },
            set: { if !$0 { model.openedDocument?.document?.buffer.hasConflict = false } }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch model.openedDocument?.state {
        case nil:
            ProgressView()
        case .failed(.missing):
            ContentUnavailableView(
                "File Not Found",
                systemImage: "questionmark.folder",
                description: Text("“\(document.relativePath)” was moved or deleted outside Markive.")
            )
        case .failed(.unreadable):
            ContentUnavailableView(
                "Can't Read Document",
                systemImage: "exclamationmark.triangle",
                description: Text("“\(document.relativePath)” is not UTF-8 text.")
            )
        case .document(let openDocument):
            presentationBody(openDocument: openDocument)
        }
    }

    @ViewBuilder
    private func presentationBody(openDocument: MarkdownDocument) -> some View {
        switch model.presentation {
        case .editor:
            MarkdownEditorView(document: openDocument)
        case .preview:
            MarkdownPreviewView(model: model, document: document, openDocument: openDocument)
        case .editorAndPreview:
            HSplitView {
                MarkdownEditorView(document: openDocument)
                    .frame(minWidth: 200)
                MarkdownPreviewView(model: model, document: document, openDocument: openDocument)
                    .frame(minWidth: 200)
            }
        }
    }
}
