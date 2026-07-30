import SwiftUI

struct TemplatePickerView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selectedTemplateID: FileID?

    private var templates: [DocumentItem] {
        model.store.templateDocuments().sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private var selectedTemplate: DocumentItem? {
        templates.first { $0.id == selectedTemplateID } ?? templates.first
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Note title", text: $title)
                Picker("Template", selection: $selectedTemplateID) {
                    ForEach(templates) { template in
                        Text(template.title).tag(Optional(template.id))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New from Template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let selectedTemplate else { return }
                        model.createDocument(named: title, from: selectedTemplate)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return)
                }
            }
        }
        .frame(width: 460, height: 240)
        .onAppear { selectedTemplateID = templates.first?.id }
    }
}
