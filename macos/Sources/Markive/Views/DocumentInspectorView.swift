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

    private func inspectorForm(for document: DocumentItem) -> some View {
        Form {
            Section("Document") {
                LabeledContent("Title", value: document.title)
                LabeledContent("Path", value: document.relativePath)
                LabeledContent("Location", value: document.url.deletingLastPathComponent().path)
            }
            Section("Dates") {
                LabeledContent("Created") {
                    Text(document.createdAt, format: .dateTime.day().month().year())
                }
                LabeledContent("Modified") {
                    Text(document.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                }
            }
            if let text = model.openedDocument?.text, model.openedDocument?.id == document.id {
                Section("Statistics") {
                    LabeledContent(
                        "Words",
                        value: text.split(whereSeparator: \.isWhitespace).count,
                        format: .number
                    )
                    LabeledContent("Characters", value: text.count, format: .number)
                }
            }
        }
        .formStyle(.grouped)
    }
}
