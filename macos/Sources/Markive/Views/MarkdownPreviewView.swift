import SwiftUI

/// Placeholder for the rendered preview. Shows the raw text — the real renderer
/// (markive-core pipeline) comes later.
struct MarkdownPreviewView: View {
    var title: String
    var text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title.bold())
                Text(text)
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
