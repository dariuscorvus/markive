import Foundation
import Observation

/// In-memory sample data for the prototype. No filesystem access, no persistence.
@MainActor
@Observable
final class PrototypeStore {
    var documents: [PrototypeDocument]
    let folderTree: [PrototypeFolder]

    init(documents: [PrototypeDocument], folderTree: [PrototypeFolder]) {
        self.documents = documents
        self.folderTree = folderTree
    }

    var allTags: [String] {
        Array(Set(documents.flatMap(\.tags))).sorted()
    }

    var favoriteCount: Int {
        documents.count(where: \.isFavorite)
    }

    func document(id: PrototypeDocument.ID) -> PrototypeDocument? {
        documents.first { $0.id == id }
    }

    func updateContent(id: PrototypeDocument.ID, content: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].content = content
        documents[index].modifiedAt = .now
    }

    func touch(id: PrototypeDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].modifiedAt = .now
    }

    func toggleFavorite(id: PrototypeDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].isFavorite.toggle()
    }

    func resolveExternalChange(id: PrototypeDocument.ID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents[index].status = .ok
    }

    func remove(id: PrototypeDocument.ID) {
        documents.removeAll { $0.id == id }
    }

    func createDocument(inFolder folder: String = "Notes") -> PrototypeDocument {
        let untitled = documents.count(where: { $0.title.hasPrefix("Untitled") })
        let title = untitled == 0 ? "Untitled" : "Untitled \(untitled + 1)"
        let document = PrototypeDocument(
            title: title,
            folder: folder,
            modifiedAt: .now,
            createdAt: .now,
            content: "# \(title)\n\n"
        )
        documents.insert(document, at: 0)
        return document
    }

    func backlinks(to document: PrototypeDocument) -> [PrototypeDocument] {
        documents.filter { $0.id != document.id && $0.content.contains("[[\(document.title)]]") }
    }

    static func sample() -> PrototypeStore {
        let now = Date.now
        func daysAgo(_ days: Double, hours: Double = 0) -> Date {
            now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
        }

        let folderTree: [PrototypeFolder] = [
            PrototypeFolder(id: "Notes", name: "Notes", children: [
                PrototypeFolder(id: "Notes/Projects", name: "Projects", children: nil),
                PrototypeFolder(id: "Notes/Ideas", name: "Ideas", children: nil),
            ]),
            PrototypeFolder(id: "Journal", name: "Journal", children: nil),
            PrototypeFolder(id: "Reading", name: "Reading", children: nil),
        ]

        let documents: [PrototypeDocument] = [
            PrototypeDocument(
                title: "Markive Roadmap",
                folder: "Notes/Projects",
                modifiedAt: daysAgo(0, hours: 2),
                createdAt: daysAgo(90),
                isFavorite: true,
                tags: ["markive", "planning"],
                content: """
                # Markive Roadmap

                The native shell ships in three stages. See [[SwiftUI Port Notes]] \
                for the editor decision and [[Renderer Ideas]] for preview work.

                - [ ] Window structure prototype
                - [ ] Filesystem layer
                - [ ] TextKit 2 editor spike
                """
            ),
            PrototypeDocument(
                title: "SwiftUI Port Notes",
                folder: "Notes/Projects",
                modifiedAt: daysAgo(1),
                createdAt: daysAgo(10),
                tags: ["markive", "swift"],
                content: """
                # SwiftUI Port Notes

                Parsing stays in `markive-core` (Rust, FFI-ready). The UI layer is \
                pure SwiftUI; the editor is the open question. Related: [[Markive Roadmap]].
                """
            ),
            PrototypeDocument(
                title: "Renderer Ideas",
                folder: "Notes/Ideas",
                modifiedAt: daysAgo(3),
                createdAt: daysAgo(30),
                tags: ["ideas", "markive"],
                content: """
                # Renderer Ideas

                Preview should reuse the sanitizer pipeline. Candidates: AttributedString \
                markdown, TextKit 2 custom layout, or keeping the web preview.
                """
            ),
            PrototypeDocument(
                title: "2026-07-26",
                folder: "Journal",
                modifiedAt: daysAgo(0, hours: 1),
                createdAt: daysAgo(0, hours: 8),
                tags: ["journal"],
                content: """
                # 2026-07-26

                Started the native window-structure prototype. Linked from [[Markive Roadmap]].
                """
            ),
            PrototypeDocument(
                title: "2026-07-25",
                folder: "Journal",
                modifiedAt: daysAgo(1, hours: 5),
                createdAt: daysAgo(1, hours: 9),
                tags: ["journal"],
                content: """
                # 2026-07-25

                Reviewed the wireframe spec. Sidebar sections settled.
                """
            ),
            PrototypeDocument(
                title: "Reading List",
                folder: "Reading",
                modifiedAt: daysAgo(6),
                createdAt: daysAgo(200),
                isFavorite: true,
                tags: ["reading"],
                content: """
                # Reading List

                - The Mythical Man-Month
                - Working in Public
                - [[Renderer Ideas]] references chapter 4
                """
            ),
            PrototypeDocument(
                title: "Travel Plans",
                folder: "Notes",
                location: .iCloudDrive,
                modifiedAt: daysAgo(12),
                createdAt: daysAgo(40),
                tags: ["personal"],
                content: """
                # Travel Plans

                Fall trip options, no bookings yet.
                """
            ),
            PrototypeDocument(
                title: "Grocery Scratchpad",
                folder: "Notes",
                modifiedAt: daysAgo(2),
                createdAt: daysAgo(2),
                content: """
                # Grocery Scratchpad

                Oat milk, coffee, rye bread.
                """
            ),
            PrototypeDocument(
                title: "Meeting Notes",
                folder: "Notes",
                modifiedAt: daysAgo(0, hours: 4),
                createdAt: daysAgo(15),
                tags: ["work"],
                status: .externallyChanged,
                content: """
                # Meeting Notes

                Sync on the native prototype. Action items in [[Markive Roadmap]].
                """
            ),
            PrototypeDocument(
                title: "Old Draft",
                folder: "Notes",
                modifiedAt: daysAgo(120),
                createdAt: daysAgo(150),
                status: .missing,
                content: ""
            ),
            PrototypeDocument(
                title: "Binary Blob Import",
                folder: "Reading",
                modifiedAt: daysAgo(60),
                createdAt: daysAgo(60),
                status: .unreadable,
                content: ""
            ),
        ]

        return PrototypeStore(documents: documents, folderTree: folderTree)
    }
}
