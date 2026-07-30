import AppKit
import SwiftUI

/// Quick Open (⌘P) — a standard sheet with a searchable document list.
struct QuickOpenView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: FileID?
    @State private var keyMonitor: Any?

    private var matches: [DocumentItem] {
        if query.isEmpty {
            return model.store.documents.sorted { $0.modifiedAt > $1.modifiedAt }
        }
        let indexed = model.store.knowledgeIndex.completions(matching: query)
        if !indexed.isEmpty {
            let ids = Set(indexed.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: model.store.documents.map { ($0.id, $0) })
            return indexed.compactMap { byID[$0.id] }.filter { ids.contains($0.id) }
        }
        return model.store.documents.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedDocument: DocumentItem? {
        matches.first { $0.id == selectedID } ?? matches.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(matches, selection: $selectedID) { document in
                        Button {
                            open(document)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                Text(document.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .tag(document.id)
                    }
                }
            }
            .searchable(text: $query, prompt: "Document name or path")
            .onSubmit(of: .search) {
                if let selectedDocument { open(selectedDocument) }
            }
            .navigationTitle("Quick Open")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem {
                    Button("Create “\(query)”") {
                        createExactQuery()
                    }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.shift])
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        if let selectedDocument { open(selectedDocument) }
                    }
                    .disabled(selectedDocument == nil)
                    .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .onMoveCommand(perform: moveSelection)
        .onKeyPress(.upArrow) {
            moveSelection(.up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(.down)
            return .handled
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .onChange(of: matches.map(\.id), initial: true) {
            if selectedID == nil || !matches.contains(where: { $0.id == selectedID }) {
                selectedID = matches.first?.id
            }
        }
    }

    private func open(_ document: DocumentItem) {
        model.presentation = .preview
        model.open(document)
        dismiss()
    }

    private func createExactQuery() {
        guard model.createDocument(named: query) != nil else { return }
        dismiss()
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !matches.isEmpty else { return }
        let current = matches.firstIndex { $0.id == selectedID } ?? 0
        let next = direction == .up
            ? max(0, current - 1)
            : min(matches.count - 1, current + 1)
        selectedID = matches[next].id
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.isKeyWindow == true,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return event
            }
            switch event.keyCode {
            case 125:
                moveSelection(.down)
                return nil
            case 126:
                moveSelection(.up)
                return nil
            case 36, 76:
                if event.modifierFlags.contains(.shift) {
                    createExactQuery()
                } else if let selectedDocument {
                    open(selectedDocument)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
