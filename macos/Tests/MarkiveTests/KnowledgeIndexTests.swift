import Foundation
import Testing
@testable import Markive

private struct KnowledgeFixture {
    let root: URL

    init(files: [(String, String)]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkiveKnowledge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func snapshot() -> WorkspaceStore.Snapshot {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        return WorkspaceStore.scan(root: root, rootName: "Knowledge")
    }
}

private func knowledgeDefaults() -> UserDefaults {
    UserDefaults(suiteName: "markive.knowledge-tests.\(UUID().uuidString)")!
}

@Suite struct KnowledgeIndexTests {
    @Test func indexesSearchesResolvesAndRewritesKnowledge() throws {
        let fixture = try KnowledgeFixture(files: [
            ("Projects/Alpha.md", """
            ---
            aliases: [A Project]
            tags: [work, active]
            status: draft
            ---
            # Alpha

            Exact Phrase lives here.

            - [ ] Follow up

            See [[Reference#Details|source note]].
            """),
            ("Reference.md", """
            # Reference

            ## Details

            Back to [Alpha](Projects/Alpha.md).
            """),
            ("Archive/Hidden.md", "Exact Phrase in archive"),
            ("CaseLink.md", "See [[projects/alpha]]."),
        ])
        defer { fixture.remove() }

        let snapshot = fixture.snapshot()
        let index = KnowledgeIndex.build(documents: snapshot.documents)

        #expect(index.documents.count == 4)
        #expect(index.completions(matching: "A Project").first?.title == "Alpha")
        #expect(index.linkCompletions(matching: "Reference#Det") == ["Reference#Details]]"])

        let phrase = index.search(#""Exact Phrase""#)
        #expect(phrase.count == 2)
        #expect(index.search(#""Exact Phrase""#, excludedPaths: ["Archive"]).count == 1)
        #expect(index.search("tag:#work").map(\.title) == ["Alpha"])
        #expect(index.search("[status:draft]").map(\.title) == ["Alpha"])
        #expect(index.search("exact phrase", caseSensitive: true).isEmpty)

        let alpha = try #require(index.documents.first { $0.title == "Alpha" })
        let reference = try #require(index.documents.first { $0.title == "Reference" })
        let caseLink = try #require(index.documents.first { $0.title == "CaseLink" })
        #expect(alpha.analysis.tasks.count == 1)
        #expect(index.backlinks(to: alpha.relativePath).map(\.sourceTitle) == ["CaseLink", "Reference"])

        let wikilink = try #require(alpha.analysis.links.first { $0.kind == .wikilink })
        #expect(index.resolve(wikilink, from: alpha.relativePath) == .resolved(reference))
        let caseInsensitivePathLink = try #require(caseLink.analysis.links.first)
        #expect(index.resolve(caseInsensitivePathLink, from: caseLink.relativePath) == .resolved(alpha))

        let rendered = index.renderableMarkdown(alpha.content, sourcePath: alpha.relativePath)
        #expect(rendered.contains("[source note](../Reference.md#details)"))
        #expect(!rendered.contains("aliases:"))
        #expect(rendered.hasPrefix("# Alpha"))

        let dashboard = index.renderableMarkdown(
            """
            ```dataview
            TABLE status, file.mtime AS "Modified"
            FROM "Projects"
            SORT file.mtime DESC
            LIMIT 10
            ```
            """,
            sourcePath: "Reference.md"
        )
        #expect(dashboard.contains("| Note | status | Modified |"))
        #expect(dashboard.contains("[Alpha](Projects/Alpha.md) | draft |"))
        #expect(!dashboard.contains("```dataview"))

        let rewritten = index.rewritingInboundLinks(
            from: alpha.relativePath,
            to: "Projects/Renamed.md"
        )
        #expect(rewritten["Reference.md"]?.contains("[Alpha](Projects/Renamed.md)") == true)
    }

    @Test func rebuildReusesUnchangedEntriesAndDropsDeletedFiles() throws {
        let fixture = try KnowledgeFixture(files: [
            ("Keep.md", "# Keep"),
            ("Delete.md", "# Delete"),
        ])
        defer { fixture.remove() }

        let firstSnapshot = fixture.snapshot()
        let first = KnowledgeIndex.build(documents: firstSnapshot.documents)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Delete.md"))
        let secondSnapshot = fixture.snapshot()
        let second = KnowledgeIndex.build(documents: secondSnapshot.documents, reusing: first)

        #expect(second.documents.map(\.title) == ["Keep"])
        #expect(second.documents.first?.content == first.documentsByPath["Keep.md"]?.content)
    }

    @Test func tenThousandPathCompletionsStayInteractive() {
        var documents: [String: IndexedDocument] = [:]
        let analysis = DocumentAnalysis(
            headings: [],
            links: [],
            properties: [],
            aliases: [],
            tags: [],
            tasks: [],
            frontmatterError: nil
        )
        for number in 0..<10_000 {
            let path = "Notes/Note-\(number).md"
            let id = FileID(device: 1, inode: number)
            documents[path] = IndexedDocument(
                id: id,
                diskID: id,
                relativePath: path,
                title: "Note \(number)",
                modifiedAt: .distantPast,
                content: "",
                analysis: analysis
            )
        }
        let index = KnowledgeIndex(documentsByPath: documents)
        let start = ContinuousClock.now
        let matches = index.completions(matching: "Note 999", limit: 50)
        let elapsed = ContinuousClock.now - start

        #expect(!matches.isEmpty)
        #expect(elapsed < .seconds(1), "10,000-path completion took \(elapsed)")
    }

    @Test func rewritesSeveralMovedTargetsUsingTheMovedSourceFolder() throws {
        let fixture = try KnowledgeFixture(files: [
            ("Notes/Source.md", "See [one](One.md) and [two](Two.md).\n"),
            ("Notes/One.md", "# One"),
            ("Notes/Two.md", "# Two"),
            ("Outside.md", "See [one](Notes/One.md) and [[Notes/Two]].\n"),
        ])
        defer { fixture.remove() }

        let snapshot = WorkspaceStore.scan(root: fixture.root, rootName: "Fixture")
        let index = KnowledgeIndex.build(documents: snapshot.documents)
        let rewritten = index.rewritingInboundLinks(moving: [
            "Notes/Source.md": "Archive/Source.md",
            "Notes/One.md": "Archive/One.md",
            "Notes/Two.md": "Archive/Two.md",
        ])

        #expect(rewritten["Notes/Source.md"] == nil)
        #expect(rewritten["Outside.md"]?.contains("[one](Archive/One.md)") == true)
        #expect(rewritten["Outside.md"]?.contains("[[Archive/Two]]") == true)
    }

    @Test func movingASourceRebasesLinksToTargetsThatStayPut() throws {
        let fixture = try KnowledgeFixture(files: [
            ("Notes/Source.md", "See [target](Target.md).\n"),
            ("Notes/Target.md", "# Target"),
        ])
        defer { fixture.remove() }

        let snapshot = WorkspaceStore.scan(root: fixture.root, rootName: "Fixture")
        let index = KnowledgeIndex.build(documents: snapshot.documents)
        let rewritten = index.rewritingInboundLinks(moving: [
            "Notes/Source.md": "Archive/Deep/Source.md",
        ])

        #expect(rewritten["Notes/Source.md"] == "See [target](../../Notes/Target.md).\n")
    }

    @Test func expandsImageDocumentHeadingAndBlockEmbeds() throws {
        let fixture = try KnowledgeFixture(files: [
            ("Notes/Source.md", """
            ![[images/photo.png]]

            ![[Reference]]

            ![[Reference#Details]]

            ![[Reference#^important]]
            """),
            ("Notes/Reference.md", """
            ---
            status: draft
            ---
            # Reference

            Intro.

            ## Details

            Included detail.

            A cited paragraph. ^important

            ## Later

            Excluded detail.
            """),
        ])
        defer { fixture.remove() }
        let index = KnowledgeIndex.build(documents: fixture.snapshot().documents)
        let source = try #require(index.documentsByPath["Notes/Source.md"])

        let rendered = index.renderableMarkdown(source.content, sourcePath: source.relativePath)

        #expect(rendered.contains("![images/photo.png](images/photo.png)"))
        #expect(rendered.contains("Embedded: [Reference](Reference.md)"))
        #expect(rendered.contains("Included detail."))
        #expect(rendered.contains("A cited paragraph."))
        #expect(!rendered.contains("status: draft"))
        #expect(rendered.components(separatedBy: "Excluded detail.").count == 2)
        #expect(!rendered.contains("^important"))
    }

    @Test func embedFailuresAreVisibleAndRecursionIsBounded() throws {
        let fixture = try KnowledgeFixture(files: [
            ("A.md", "![[B]]\n\n![[Missing]]\n\n![[B#No Such Heading]]\n\n![[One]]"),
            ("B.md", "![[A]]"),
            ("One.md", "![[Two]]"),
            ("Two.md", "![[Three]]"),
            ("Three.md", "![[Four]]"),
            ("Four.md", "![[Five]]"),
            ("Five.md", "![[Six]]"),
            ("Six.md", "Too deep"),
        ])
        defer { fixture.remove() }
        let index = KnowledgeIndex.build(documents: fixture.snapshot().documents)
        let source = try #require(index.documentsByPath["A.md"])

        let rendered = index.renderableMarkdown(source.content, sourcePath: source.relativePath)

        #expect(rendered.contains("Circular embed: A.md"))
        #expect(rendered.contains("Missing embed: Missing"))
        #expect(rendered.contains("Missing section: B.md#No Such Heading"))
        #expect(rendered.contains("Embed depth limit reached: Five.md"))
        #expect(!rendered.contains("Too deep"))
        #expect(rendered.utf8.count < 10_000)
    }

    @Test func nestedImageEmbedsStayRelativeToTheirOwningDocument() throws {
        let fixture = try KnowledgeFixture(files: [
            ("Notes/Source.md", "![[../Library/Reference]]"),
            ("Library/Reference.md", "![[media/nested image.png]]"),
        ])
        defer { fixture.remove() }
        let index = KnowledgeIndex.build(documents: fixture.snapshot().documents)
        let source = try #require(index.documentsByPath["Notes/Source.md"])

        let rendered = index.renderableMarkdown(source.content, sourcePath: source.relativePath)

        #expect(rendered.contains("(../Library/media/nested%20image.png)"))
    }
}

@Suite struct DailyNoteTests {
    @MainActor
    @Test func readsObsidianSettingsCreatesFoldersExpandsTemplateAndNeverOverwrites() async throws {
        let fixture = try KnowledgeFixture(files: [
            (".obsidian/daily-notes.json", """
            {"folder":"10--inbox/daily","format":"YYYY/MM/YYYY-MM-DD","template":"Templates/Daily.md"}
            """),
            (".obsidian/templates.json", #"{"folder":"Templates"}"#),
            ("Templates/Daily.md", "# {{title}}\n\nCreated {{date}} at {{time:HH:mm}}\n"),
        ])
        defer { fixture.remove() }

        let store = WorkspaceStore(defaults: knowledgeDefaults())
        await store.openWorkspace(at: fixture.root)
        let calendar = Calendar(identifier: .gregorian)
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 29, hour: 9, minute: 42
        )))

        let first = try store.createDailyDocument(on: date)
        #expect(first.created)
        #expect(first.0.relativePath == "10--inbox/daily/2026/07/2026-07-29.md")
        let content = try String(contentsOf: first.0.url, encoding: .utf8)
        #expect(content.contains("# 2026-07-29"))
        #expect(content.contains("Created 2026-07-29 at 09:42"))

        try "preserve me".write(to: first.0.url, atomically: true, encoding: .utf8)
        let second = try store.createDailyDocument(on: date)
        #expect(!second.created)
        #expect(try String(contentsOf: second.0.url, encoding: .utf8) == "preserve me")
    }
}

@Suite struct LinkPreservingRenameTests {
    @MainActor
    @Test func renameUpdatesInboundMarkdownAndWikilinks() async throws {
        let fixture = try KnowledgeFixture(files: [
            ("Notes/Target.md", "# Target"),
            ("Source.md", "See [[Notes/Target|target]] and [target](Notes/Target.md).\n"),
        ])
        defer { fixture.remove() }

        let store = WorkspaceStore(defaults: knowledgeDefaults())
        await store.openWorkspace(at: fixture.root)
        let target = try #require(store.documents.first { $0.title == "Target" })
        _ = try store.rename(target, to: "Renamed")

        let source = try String(
            contentsOf: fixture.root.appendingPathComponent("Source.md"),
            encoding: .utf8
        )
        #expect(source.contains("[[Notes/Renamed|target]]"))
        #expect(source.contains("[target](Notes/Renamed.md)"))
    }
}

@Suite struct MigrationVerificationTests {
    @Test func currentVaultIndexesWithoutChangingFiles() throws {
        guard let path = ProcessInfo.processInfo.environment["MARKIVE_MIGRATION_VAULT"] else {
            return
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let before = fileSignatures(root: root)
        let snapshot = WorkspaceStore.scan(root: root, rootName: root.lastPathComponent)
        let index = KnowledgeIndex.build(documents: snapshot.documents)
        let after = fileSignatures(root: root)
        let errors = index.documents.compactMap { document in
            document.analysis.frontmatterError.map { (document.relativePath, $0) }
        }
        let wikilinkResolutions = index.documents.flatMap { document in
            document.analysis.links
                .filter { $0.kind == .wikilink }
                .map { (document.relativePath, $0, index.resolve($0, from: document.relativePath)) }
        }
        let resolvedWikilinks = wikilinkResolutions.filter {
            if case .resolved = $0.2 { true } else { false }
        }
        let ambiguousWikilinks = wikilinkResolutions.filter {
            if case .ambiguous = $0.2 { true } else { false }
        }
        let brokenWikilinks = wikilinkResolutions.filter {
            if case .broken = $0.2 { true } else { false }
        }
        print(
            "Migration: readable=\(before.count), indexed=\(index.documents.count), "
                + "properties=\(index.documents.filter { !$0.analysis.properties.isEmpty }.count), "
                + "wikilinks=\(wikilinkResolutions.count), resolved=\(resolvedWikilinks.count), "
                + "ambiguous=\(ambiguousWikilinks.count), broken=\(brokenWikilinks.count), "
                + "tasks=\(index.documents.flatMap(\.analysis.tasks).count), errors=\(errors.count)"
        )
        for error in errors.prefix(20) {
            print("Frontmatter error \(error.0): \(error.1)")
        }
        for broken in brokenWikilinks.prefix(20) {
            print("Broken wikilink \(broken.0): \(broken.1.target)")
        }

        #expect(index.documents.count == before.count)
        #expect(index.documents.count >= 235)
        #expect(index.documents.filter { !$0.analysis.properties.isEmpty }.count >= 70)
        #expect(index.documents.flatMap(\.analysis.links).filter { $0.kind == .wikilink }.count >= 289)
        #expect(index.documents.flatMap(\.analysis.tasks).count >= 257)
        #expect(index.documents.compactMap(\.analysis.frontmatterError).isEmpty)
        #expect(before.allSatisfy { after[$0.key] == $0.value })
    }

    private func fileSignatures(root: URL) -> [String: String] {
        let snapshot = WorkspaceStore.scan(root: root, rootName: root.lastPathComponent)
        return Dictionary(uniqueKeysWithValues: snapshot.documents.compactMap {
            guard let data = try? Data(contentsOf: $0.url) else { return nil }
            return ($0.relativePath, data.base64EncodedString())
        })
    }
}
