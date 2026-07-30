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

    @Test func hiddenFilesCanBeIncludedWithoutTraversingRepositoryInternals() throws {
        let fixture = try FixtureWorkspace(files: [
            ("visible.md", "v"),
            (".private.md", "private"),
            (".notes/inside.md", "inside"),
            (".git/objects/readme.md", "not a document"),
        ])
        defer { fixture.tearDown() }

        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let snapshot = WorkspaceStore.scan(
            root: root,
            rootName: "Fixture",
            policy: WorkspaceScanPolicy(showHiddenFiles: true)
        )

        #expect(Set(snapshot.documents.map(\.relativePath)) == [
            "visible.md", ".private.md", ".notes/inside.md",
        ])
        #expect(snapshot.folders.map(\.id) == [".notes"])
    }

    @Test func rootLevelScanExposesNavigationWithoutWalkingTheTree() throws {
        let fixture = try FixtureWorkspace(files: [
            ("root.md", "root"),
            ("Large/Deep/Nested.md", "nested"),
        ])
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Empty", isDirectory: true),
            withIntermediateDirectories: true
        )

        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let initial = WorkspaceStore.scanRootLevel(root: root, rootName: "Fixture")

        #expect(initial.documents.map(\.relativePath) == ["root.md"])
        #expect(initial.folders.map(\.id) == ["Empty", "Large"])
        #expect(initial.folders.allSatisfy { $0.children == nil })
    }

    @Test func emptyFoldersRemainInTheRecursiveTree() throws {
        let fixture = try FixtureWorkspace(files: [("HasNote/note.md", "note")])
        defer { fixture.tearDown() }
        try FileManager.default.createDirectory(
            at: fixture.root.appendingPathComponent("Empty/Nested", isDirectory: true),
            withIntermediateDirectories: true
        )

        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let snapshot = WorkspaceStore.scan(root: root, rootName: "Fixture")

        let empty = try #require(snapshot.folders.first { $0.id == "Empty" })
        #expect(empty.children?.map(\.id) == ["Empty/Nested"])
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

@Suite struct DocumentSessionTests {
    @MainActor
    @Test func opensEditsWritesAndCaches() throws {
        let fixture = try FixtureWorkspace(files: [("doc.md", "# Hello\n\nWörld — ünïcode")])
        defer { fixture.tearDown() }
        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let item = try #require(WorkspaceStore.item(
            at: root.appendingPathComponent("doc.md"), root: root, rootName: "F"
        ))

        let session = DocumentSession()
        let document = try session.document(for: item)
        #expect(document.buffer.text.contains("Wörld — ünïcode"))
        #expect(!document.hasUnautosavedChanges)

        document.replaceText("# Changed")
        #expect(document.hasUnautosavedChanges)

        try document.write(to: item.url, ofType: MarkdownDocument.markdownType)
        let onDisk = try String(contentsOf: item.url, encoding: .utf8)
        #expect(onDisk == "# Changed")

        #expect(try session.document(for: item) === document)
    }

    @MainActor
    @Test func bufferRevisionTracksStorageEdits() throws {
        let fixture = try FixtureWorkspace(files: [("doc.md", "start")])
        defer { fixture.tearDown() }
        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let item = try #require(WorkspaceStore.item(
            at: root.appendingPathComponent("doc.md"), root: root, rootName: "F"
        ))
        let document = try DocumentSession().document(for: item)
        let before = document.buffer.revision

        // Direct storage mutation — the path the editor view uses.
        document.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: 5),
            with: "changed"
        )
        #expect(document.buffer.revision > before)
        #expect(document.buffer.text == "changed")
    }

    @MainActor
    @Test func twentyMegabyteStorageRoundTripWithinBudget() throws {
        var markdown = "# Perf fixture\n\n"
        markdown.reserveCapacity(21 * 1024 * 1024)
        var line = 0
        while markdown.utf8.count < 20 * 1024 * 1024 {
            markdown += "## Section \(line)\n\nSome *inline* text with `code` and a [link](https://example.com/\(line)).\n\n"
            line += 1
        }
        let fixture = try FixtureWorkspace(files: [("big.md", markdown)])
        defer { fixture.tearDown() }
        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let item = try #require(WorkspaceStore.item(
            at: root.appendingPathComponent("big.md"), root: root, rootName: "F"
        ))

        let openStart = ContinuousClock.now
        let document = try DocumentSession().document(for: item)
        let openElapsed = ContinuousClock.now - openStart
        #expect(document.textStorage.length > 19_000_000)

        let editStart = ContinuousClock.now
        document.textStorage.replaceCharacters(
            in: NSRange(location: document.textStorage.length, length: 0),
            with: "x"
        )
        let editElapsed = ContinuousClock.now - editStart

        let serializeStart = ContinuousClock.now
        _ = try document.data(ofType: MarkdownDocument.markdownType)
        let serializeElapsed = ContinuousClock.now - serializeStart

        print("20 MB storage: open \(openElapsed), append \(editElapsed), serialize \(serializeElapsed)")
        #expect(openElapsed < .seconds(5), "open took \(openElapsed)")
        #expect(editElapsed < .seconds(1), "append took \(editElapsed)")
        #expect(serializeElapsed < .seconds(5), "serialize took \(serializeElapsed)")
    }

    @MainActor
    @Test func binaryFileThrowsUnreadable() throws {
        let fixture = try FixtureWorkspace(data: [("blob.md", [0xFF, 0xFE, 0x00, 0xD8])])
        defer { fixture.tearDown() }
        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let item = try #require(WorkspaceStore.item(
            at: root.appendingPathComponent("blob.md"), root: root, rootName: "F"
        ))
        let session = DocumentSession()
        #expect(throws: DocumentLoadFailure.unreadable) {
            try session.document(for: item)
        }
    }

    @MainActor
    @Test func missingFileThrowsMissing() throws {
        let fixture = try FixtureWorkspace()
        defer { fixture.tearDown() }
        let item = DocumentItem(
            id: FileID(device: 0, inode: 0),
            diskID: FileID(device: 0, inode: 0),
            url: fixture.root.appendingPathComponent("gone.md"),
            title: "gone",
            relativePath: "gone.md",
            relativeFolder: "",
            folderLabel: "F",
            modifiedAt: .distantPast,
            createdAt: .distantPast
        )
        let session = DocumentSession()
        #expect(throws: DocumentLoadFailure.missing) {
            try session.document(for: item)
        }
    }
}

@Suite struct ExternalChangeTests {
    /// Writes new content with a modification date clearly newer than the
    /// document's known one — filesystem timestamps are too coarse to rely on.
    private func writeExternally(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
    }

    @MainActor
    @Test func cleanDocumentReloadsSilently() throws {
        let fixture = try FixtureWorkspace(files: [("doc.md", "v1")])
        defer { fixture.tearDown() }
        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let item = try #require(WorkspaceStore.item(
            at: root.appendingPathComponent("doc.md"), root: root, rootName: "F"
        ))
        let document = try DocumentSession().document(for: item)

        try writeExternally("v2", to: item.url)
        document.checkExternalChange()

        #expect(document.buffer.text == "v2")
        #expect(!document.buffer.hasConflict)
    }

    @MainActor
    @Test func dirtyDocumentFlagsConflictAndKeepsEdits() throws {
        let fixture = try FixtureWorkspace(files: [("doc.md", "v1")])
        defer { fixture.tearDown() }
        let root = fixture.root.standardizedFileURL.resolvingSymlinksInPath()
        let item = try #require(WorkspaceStore.item(
            at: root.appendingPathComponent("doc.md"), root: root, rootName: "F"
        ))
        let document = try DocumentSession().document(for: item)
        document.replaceText("local edit")

        try writeExternally("v2", to: item.url)
        document.checkExternalChange()

        #expect(document.buffer.hasConflict)
        #expect(document.buffer.text == "local edit")

        document.resolveConflictReloading()
        #expect(document.buffer.text == "v2")
        #expect(!document.buffer.hasConflict)
    }

    @MainActor
    @Test func rescanPreservesIdentityAcrossExternalRename() async throws {
        let fixture = try FixtureWorkspace(files: [("Before.md", "content")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)
        let before = try #require(store.documents.first)

        try FileManager.default.moveItem(
            at: before.url,
            to: before.url.deletingLastPathComponent().appendingPathComponent("After.md")
        )
        await store.rescan()

        let after = try #require(store.documents.first)
        #expect(after.id == before.id)
        #expect(after.title == "After")
    }

    @MainActor
    @Test func rescanReconcilesOpenDocuments() async throws {
        // The presenter path (NSFilePresenter) doesn't fire for uncoordinated
        // writers; the rescan must reconcile open buffers itself.
        let fixture = try FixtureWorkspace(files: [("doc.md", "v1")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)
        let item = try #require(store.documents.first)
        let document = try store.session.document(for: item)
        #expect(document.buffer.text == "v1")

        try writeExternally("v2", to: item.url)
        await store.rescan()

        #expect(document.buffer.text == "v2")
    }

    @MainActor
    @Test func autosaveKeepsDocumentIdentity() async throws {
        // NSDocument's safe-save replaces the file (new inode). Identity must
        // survive it or selection drops on every autosave.
        let fixture = try FixtureWorkspace(files: [("doc.md", "v1")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)
        let original = try #require(store.documents.first)
        let document = try store.session.document(for: original)

        document.replaceText("edited")
        await withCheckedContinuation { continuation in
            document.autosave(withImplicitCancellability: false) { _ in
                continuation.resume()
            }
        }
        #expect(try String(contentsOf: original.url, encoding: .utf8) == "edited")

        await store.rescan()
        #expect(store.documents.count == 1, "the safe-save backup file must not be listed")
        let after = try #require(store.documents.first)
        #expect(after.id == original.id, "identity must survive a safe-save inode change")
    }

    @MainActor
    @Test func watcherPicksUpExternalCreate() async throws {
        let fixture = try FixtureWorkspace(files: [("one.md", "1")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)
        #expect(store.documents.count == 1)

        try "2".write(
            to: fixture.root.appendingPathComponent("two.md"),
            atomically: true,
            encoding: .utf8
        )

        var found = false
        for _ in 0..<50 {
            if store.documents.count == 2 { found = true; break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(found, "watcher did not trigger a rescan within 10 s")
    }
}

@Suite struct WriteOperationTests {
    @MainActor
    @Test func createNumbersUntitledDocuments() async throws {
        let fixture = try FixtureWorkspace(files: [("Sub/existing.md", "x")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)

        let first = try store.createDocument(inFolder: nil)
        let second = try store.createDocument(inFolder: nil)
        let nested = try store.createDocument(inFolder: "Sub")

        #expect(first.title == "Untitled")
        #expect(second.title == "Untitled 2")
        #expect(nested.relativePath == "Sub/Untitled.md")
        #expect(FileManager.default.fileExists(atPath: first.url.path))
        #expect(store.documents.count == 4)
    }

    @MainActor
    @Test func renameKeepsIdentityAndUpdatesMetadata() async throws {
        let fixture = try FixtureWorkspace(files: [("one.md", "1"), ("two.md", "2")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)
        let one = try #require(store.documents.first { $0.title == "one" })

        let renamed = try store.rename(one, to: "renamed")
        #expect(renamed.id == one.id)
        #expect(renamed.relativePath == "renamed.md")
        #expect(!FileManager.default.fileExists(atPath: one.url.path))
        #expect(FileManager.default.fileExists(atPath: renamed.url.path))
        #expect(store.documents.contains { $0.id == one.id && $0.title == "renamed" })

        #expect(throws: WorkspaceStore.WriteError.self) {
            try store.rename(renamed, to: "two")
        }
        #expect(throws: WorkspaceStore.WriteError.self) {
            try store.rename(renamed, to: "a/b")
        }
    }

    @MainActor
    @Test func trashRemovesDocument() async throws {
        let fixture = try FixtureWorkspace(files: [("doomed.md", "bye")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)
        let doomed = try #require(store.documents.first)

        let trashedURL = try store.trash(doomed)
        #expect(!FileManager.default.fileExists(atPath: doomed.url.path))
        #expect(store.documents.isEmpty)
        if let trashedURL {
            try? FileManager.default.removeItem(at: trashedURL)
        }
    }
}

@Suite struct FavoritesTests {
    @MainActor
    @Test func favoritesPersistPerWorkspace() async throws {
        let fixture = try FixtureWorkspace(files: [("a.md", "a"), ("b.md", "b")])
        defer { fixture.tearDown() }
        let defaults = isolatedDefaults()

        let store = WorkspaceStore(defaults: defaults)
        await store.openWorkspace(at: fixture.root)
        let a = try #require(store.documents.first { $0.title == "a" })
        store.toggleFavorite(a)
        #expect(store.isFavorite(a))
        #expect(store.favoriteDocuments.map(\.title) == ["a"])

        // A fresh store over the same defaults and root sees the favorite.
        let second = WorkspaceStore(defaults: defaults)
        await second.openWorkspace(at: fixture.root)
        #expect(second.favoriteDocuments.map(\.title) == ["a"])

        second.toggleFavorite(try #require(second.documents.first { $0.title == "a" }))
        #expect(second.favoriteDocuments.isEmpty)
    }

    @MainActor
    @Test func renameCarriesFavoriteAndTrashDropsIt() async throws {
        let fixture = try FixtureWorkspace(files: [("a.md", "a")])
        defer { fixture.tearDown() }
        let store = WorkspaceStore(defaults: isolatedDefaults())
        await store.openWorkspace(at: fixture.root)
        let a = try #require(store.documents.first)
        store.toggleFavorite(a)

        let renamed = try store.rename(a, to: "renamed")
        #expect(store.isFavorite(renamed))
        #expect(store.favoriteDocuments.map(\.title) == ["renamed"])

        let trashedURL = try store.trash(renamed)
        #expect(store.favoriteDocuments.isEmpty)
        if let trashedURL {
            try? FileManager.default.removeItem(at: trashedURL)
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
