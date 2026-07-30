import SwiftUI

struct DocumentInspectorView: View {
    @Bindable var model: WorkspaceModel
    @State private var fileInfoExpanded = false

    var body: some View {
        Group {
            if let document = model.selectedDocument {
                inspectorForm(for: document)
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "info.circle",
                    description: Text("Select a document to see its context.")
                )
            }
        }
        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
    }

    private func inspectorForm(for document: DocumentItem) -> some View {
        let indexed = model.store.knowledgeIndex.documentsByPath[document.relativePath]
        let backlinks = model.store.knowledgeIndex.backlinks(to: document.relativePath)

        return Form {
            if model.store.isIndexing {
                ProgressView("Indexing…")
            }
            if let indexed {
                if let error = indexed.analysis.frontmatterError {
                    Section("Frontmatter") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !indexed.analysis.properties.isEmpty {
                    Section("Properties") {
                        ForEach(indexed.analysis.properties) { property in
                            LabeledContent(property.name, value: property.displayValue)
                        }
                    }
                }
                if !indexed.analysis.tags.isEmpty {
                    Section("Tags") {
                        FlowLayout(spacing: 5) {
                            ForEach(indexed.analysis.tags, id: \.self) { tag in
                                Text("#\(tag)")
                                    .font(.caption)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                    }
                }
                if !backlinks.isEmpty {
                    Section("Backlinks") {
                        ForEach(backlinks) { backlink in
                            Button {
                                model.openSearchResult(SearchResult(
                                    id: backlink.id,
                                    documentID: backlink.sourceDocumentID,
                                    relativePath: backlink.sourcePath,
                                    title: backlink.sourceTitle,
                                    line: backlink.line,
                                    lineText: backlink.context,
                                    utf16Location: backlink.utf16Location,
                                    utf16Length: backlink.utf16Length
                                ))
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backlink.sourceTitle)
                                    Text(backlink.context)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                "Backlink from \(backlink.sourceTitle), line \(backlink.line)"
                            )
                        }
                    }
                }
                if !indexed.analysis.links.isEmpty {
                    Section("Outgoing Links") {
                        ForEach(Array(indexed.analysis.links.enumerated()), id: \.offset) { _, link in
                            outgoingLinkRow(link, sourcePath: indexed.relativePath)
                        }
                    }
                }
            }
            DisclosureGroup("File Info", isExpanded: $fileInfoExpanded) {
                LabeledContent("Title", value: document.title)
                LabeledContent("Path", value: document.relativePath)
                LabeledContent("Location", value: document.url.deletingLastPathComponent().path)
                LabeledContent("Created") {
                    Text(document.createdAt, format: .dateTime.day().month().year())
                }
                LabeledContent("Modified") {
                    Text(document.modifiedAt, format: .dateTime.day().month().year().hour().minute())
                }
                if let text = model.openedDocument?.document?.buffer.text,
                   model.openedDocument?.id == document.id {
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

    @ViewBuilder
    private func outgoingLinkRow(_ link: IndexedLink, sourcePath: String) -> some View {
        switch model.store.knowledgeIndex.resolve(link, from: sourcePath) {
        case .resolved(let target):
            Button {
                model.openDocument(relativePath: target.relativePath, heading: link.heading)
            } label: {
                Label(link.display, systemImage: "arrow.up.right")
            }
            .buttonStyle(.plain)
        case .ambiguous(let targets):
            Menu {
                ForEach(targets) { target in
                    Button(target.relativePath) {
                        model.openDocument(relativePath: target.relativePath, heading: link.heading)
                    }
                }
            } label: {
                Label(link.display, systemImage: "questionmark.diamond")
                    .foregroundStyle(.orange)
            }
        case .broken:
            Label(link.display, systemImage: "link.badge.plus")
                .foregroundStyle(.red)
        case .external:
            Label(link.display, systemImage: "safari")
        }
    }
}

/// Small wrapping layout for inspector tag chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? 260
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: y + lineHeight), points)
    }
}
