import SwiftUI

struct DocumentInspectorView: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        Group {
            if let document = model.selectedDocument {
                inspectorForm(for: document)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "info.circle",
                    description: Text("Select a document to see its details.")
                )
            }
        }
        .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
    }

    private func inspectorForm(for document: PrototypeDocument) -> some View {
        Form {
            Section("Document") {
                LabeledContent("Title", value: document.title)
                LabeledContent("Path", value: document.path)
                LabeledContent("Location", value: document.location.rawValue)
            }
            Section("Dates") {
                LabeledContent("Created") {
                    Text(document.createdAt, format: .dateTime.day().month().year())
                }
                LabeledContent("Modified") {
                    Text(document.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                }
            }
            Section("Statistics") {
                LabeledContent("Words", value: document.wordCount, format: .number)
                LabeledContent("Characters", value: document.characterCount, format: .number)
            }
            Section("Tags") {
                if document.tags.isEmpty {
                    Text("No Tags")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(document.tags, id: \.self) { tag in
                        Label(tag, systemImage: "number")
                    }
                }
            }
            Section("Backlinks") {
                let backlinks = model.store.backlinks(to: document)
                if backlinks.isEmpty {
                    Text("No documents link here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backlinks) { backlink in
                        Button {
                            model.open(backlink)
                        } label: {
                            Label(backlink.title, systemImage: "doc.text")
                        }
                        .buttonStyle(.plain)
                        .help("Open “\(backlink.title)”")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
