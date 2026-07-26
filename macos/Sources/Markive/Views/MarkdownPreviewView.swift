import SwiftUI

/// Placeholder for the rendered preview. Shows the raw text — the real renderer
/// (markive-core pipeline) is out of the prototype boundary.
struct MarkdownPreviewView: View {
    var document: PrototypeDocument

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(document.title)
                    .font(.title.bold())
                Text(document.content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Preview placeholder — rendering arrives with the real pipeline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .background(.background)
        .accessibilityLabel("Markdown preview")
    }
}
