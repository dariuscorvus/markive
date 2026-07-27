import SwiftUI

/// Quick Open (⌘P) — a standard sheet with a searchable document list.
struct QuickOpenView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var matches: [DocumentItem] {
        let documents = model.store.documents
        guard !query.isEmpty else {
            return documents.sorted { $0.modifiedAt > $1.modifiedAt }
        }
        return documents.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(matches) { document in
                        Button {
                            model.open(document)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                Text(document.relativePath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(text: $query, prompt: "Document name or path")
            .onSubmit(of: .search) {
                if let first = matches.first { model.open(first) }
            }
            .navigationTitle("Quick Open")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
    }
}
