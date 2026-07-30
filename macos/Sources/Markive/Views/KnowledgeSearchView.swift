import AppKit
import SwiftUI

struct KnowledgeSearchView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isCaseSensitive = false
    @State private var excludedPaths = ""
    @State private var selectedID: SearchResult.ID?
    @State private var results: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var keyMonitor: Any?

    private var exclusions: [String] {
        excludedPaths.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private var selectedResult: SearchResult? {
        results.first { $0.id == selectedID } ?? results.first
    }

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    recentSearches
                } else if model.store.isIndexing || (isSearching && results.isEmpty) {
                    ProgressView("Indexing workspace…")
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    resultList
                }
            }
            .searchable(text: $query, prompt: "Search note content")
            .onSubmit(of: .search) { openSelection() }
            .navigationTitle("Search Workspace")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem {
                    Menu {
                        Toggle("Match Case", isOn: $isCaseSensitive)
                        TextField("Exclude paths, comma separated", text: $excludedPaths)
                            .frame(width: 260)
                    } label: {
                        Label("Search Options", systemImage: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") { openSelection() }
                        .disabled(selectedResult == nil)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
        }
        .frame(minWidth: 660, minHeight: 500)
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
        .onChange(of: results.map(\.id), initial: true) {
            if selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
                selectedID = results.first?.id
            }
        }
        .onChange(of: SearchInput(
            query: query,
            isCaseSensitive: isCaseSensitive,
            excludedPaths: excludedPaths,
            indexCount: model.store.knowledgeIndex.documents.count
        ), initial: true) {
            runSearch()
        }
    }

    private var resultList: some View {
        List(results, selection: $selectedID) { result in
            Button {
                selectedID = result.id
                openSelection()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(result.title)
                            .font(.headline)
                        Spacer()
                        Text("Line \(result.line)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let before = result.contextBefore, !before.isEmpty {
                        Text(before.trimmingCharacters(in: .whitespaces))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(result.lineText)
                        .lineLimit(2)
                    if let after = result.contextAfter, !after.isEmpty {
                        Text(after.trimmingCharacters(in: .whitespaces))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text(result.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .tag(result.id)
        }
    }

    @ViewBuilder
    private var recentSearches: some View {
        if model.store.recentSearches.isEmpty {
            ContentUnavailableView(
                "Search Your Notes",
                systemImage: "text.magnifyingglass",
                description: Text(
                    "Search words and phrases, or filter with tag:#name, path:folder, and [property:value]."
                )
            )
        } else {
            List {
                Section("Recent Searches") {
                    ForEach(model.store.recentSearches, id: \.self) { recent in
                        Button(recent) { query = recent }
                    }
                }
            }
        }
    }

    private func openSelection() {
        guard let result = selectedResult else { return }
        model.store.recordSearch(query)
        model.openSearchResult(result)
        dismiss()
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down, !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? 0
        let next = direction == .up
            ? max(0, current - 1)
            : min(results.count - 1, current + 1)
        selectedID = results[next].id
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
                openSelection()
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

    private func runSearch() {
        searchTask?.cancel()
        guard !query.isEmpty else {
            results = []
            isSearching = false
            return
        }
        let query = query
        let caseSensitive = isCaseSensitive
        let exclusions = exclusions
        let index = model.store.knowledgeIndex
        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .userInitiated) {
                index.search(
                    query,
                    caseSensitive: caseSensitive,
                    excludedPaths: exclusions
                )
            }.value
            guard !Task.isCancelled else { return }
            results = found
            isSearching = false
        }
    }
}

private struct SearchInput: Equatable {
    var query: String
    var isCaseSensitive: Bool
    var excludedPaths: String
    var indexCount: Int
}
