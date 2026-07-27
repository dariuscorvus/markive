import Foundation
import Testing
@testable import Markive

/// Builds a real temp-directory workspace per test and removes it afterwards.
private struct FixtureWorkspace {
    let root: URL

    init(files: [(path: String, content: String)] = [], data: [(path: String, bytes: [UInt8])] = []) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        for (path, bytes) in data {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(bytes).write(to: url)
        }
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "markive.tests.\(UUID().uuidString)")!
}

@Suite struct ScanTests {
    @Test func markdownFilteringAndMetadata() throws {
        let fixture = try FixtureWorkspace(files: [
            ("Roadmap.md", "# Roadmap"),
            ("notes.markdown", "notes"),
            ("ignore.txt", "not markdown"),
            (".hidden.md", "hidden file"),
            ("Sub/Deep/Nested.md", "# Nested"),
        ])
        defer { fixture.tearDown() }

        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let snapshot = WorkspaceStore.scan(root: root, rootName: "Fixture")

        let titles = Set(snapshot.documents.map(\.title))
        #expect(titles == ["Roadmap", "notes", "Nested"])

        let nested = try #require(snapshot.documents.first { $0.title == "Nested" })
        #expect(nested.relativePath == "Sub/Deep/Nested.md")
        #expect(nested.relativeFolder == "Sub/Deep")
        #expect(nested.folderLabel == "Sub/Deep")

        let roadmap = try #require(snapshot.documents.first { $0.title == "Roadmap" })
        #expect(roadmap.relativeFolder.isEmpty)
        #expect(roadmap.folderLabel == "Fixture")
    }

    @Test func folderTreeNesting() throws {
        let fixture = try FixtureWorkspace(files: [
            ("A/one.md", "1"),
            ("A/B/two.md", "2"),
            ("C/three.md", "3"),
        ])
        defer { fixture.tearDown() }

        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let snapshot = WorkspaceStore.scan(root: root, rootName: "Fixture")

        #expect(snapshot.folders.map(\.name) == ["A", "C"])
        let a = try #require(snapshot.folders.first { $0.name == "A" })
        #expect(a.children?.map(\.id) == ["A/B"])
    }

    @Test func hiddenDirectoriesAreSkipped() throws {
        let fixture = try FixtureWorkspace(files: [
            ("visible.md", "v"),
            (".git/objects/readme.md", "not a document"),
        ])
        defer { fixture.tearDown() }

        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let snapshot = WorkspaceStore.scan(root: root, rootName: "Fixture")

        #expect(snapshot.documents.map(\.title) == ["visible"])
        #expect(snapshot.folders.isEmpty)
    }

    @Test func fileIdentitySurvivesRename() throws {
        let fixture = try FixtureWorkspace(files: [("Before.md", "content")])
        defer { fixture.tearDown() }
        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()

        let before = WorkspaceStore.scan(root: root, rootName: "F").documents[0]
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("Before.md"),
            to: root.appendingPathComponent("After.md")
        )
        let after = WorkspaceStore.scan(root: root, rootName: "F").documents[0]

        #expect(before.id == after.id)
        #expect(after.title == "After")
    }
}

@Suite struct ContentTests {
    @Test func readsUTF8() throws {
        let fixture = try FixtureWorkspace(files: [("doc.md", "# Hello\n\nWörld — ünïcode")])
        defer { fixture.tearDown() }
        let text = try WorkspaceStore.readContent(at: fixture.root.appendingPathComponent("doc.md"))
        #expect(text.contains("Wörld — ünïcode"))
    }

    @Test func binaryFileIsUnreadable() throws {
        let fixture = try FixtureWorkspace(data: [("blob.md", [0xFF, 0xFE, 0x00, 0xD8])])
        defer { fixture.tearDown() }
        #expect(throws: DocumentLoadFailure.unreadable) {
            try WorkspaceStore.readContent(at: fixture.root.appendingPathComponent("blob.md"))
        }
    }

    @Test func missingFileThrowsMissing() throws {
        let fixture = try FixtureWorkspace()
        defer { fixture.tearDown() }
        #expect(throws: DocumentLoadFailure.missing) {
            try WorkspaceStore.readContent(at: fixture.root.appendingPathComponent("gone.md"))
        }
    }
}

@Suite struct RecentsTests {
    @MainActor
    @Test func openRecordsRecentsMostRecentFirstAndDeduped() async throws {
        let first = try FixtureWorkspace(files: [("a.md", "a")])
        let second = try FixtureWorkspace(files: [("b.md", "b")])
        defer {
            first.tearDown()
            second.tearDown()
        }

        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: first.root)
        await store.openWorkspace(at: second.root)
        await store.openWorkspace(at: first.root)

        let paths = store.recentWorkspaces.map(\.lastPathComponent)
        #expect(paths.count == 2)
        #expect(paths[0] == first.root.lastPathComponent)
        #expect(paths[1] == second.root.lastPathComponent)
    }

    @MainActor
    @Test func openLoadsDocumentsAndTree() async throws {
        let fixture = try FixtureWorkspace(files: [
            ("one.md", "1"),
            ("Sub/two.md", "2"),
        ])
        defer { fixture.tearDown() }

        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)

        #expect(store.rootName == fixture.root.lastPathComponent)
        #expect(Set(store.documents.map(\.title)) == ["one", "two"])
        #expect(store.folderTree.map(\.name) == ["Sub"])
        #expect(store.isLoading == false)
    }
}
