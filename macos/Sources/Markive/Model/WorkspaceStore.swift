import Foundation
import Observation

/// Disk-backed workspace: root folder, folder tree, and document metadata.
/// Document *content* is read on demand via `readContent` — nothing is cached here.
/// Read-only in this iteration; editing arrives with the NSDocument layer.
@MainActor
@Observable
final class WorkspaceStore {
    private(set) var rootURL: URL?
    private(set) var rootName: String?
    private(set) var folderTree: [FolderNode] = []
    private(set) var documents: [DocumentItem] = []
    private(set) var isLoading = false
    private(set) var isIndexing = false
    private(set) var knowledgeIndex = KnowledgeIndex.empty
    private(set) var knowledgeIndexRevision = 0
    private(set) var recentWorkspaces: [URL] = []
    private(set) var recentSearches: [String] = []
    private(set) var showHiddenFiles: Bool
    var settings = WorkspaceSettings()

    /// Set by `AppDelegate.application(_:open:)` when Finder hands the app a
    /// file to open; the main window observes this and clears it once handled.
    var pendingFileOpen: URL?

    /// Open NSDocuments, shared across windows.
    let session = DocumentSession()

    /// Favorites are app data, not file data: relative paths per workspace,
    /// persisted in defaults. Paths survive safe-saves (inodes don't); our own
    /// renames carry the favorite over, external renames lose it.
    private(set) var favoritePaths: Set<String> = []

    private let defaults: UserDefaults
    private var securityScopedRoot: URL?
    private var scanGeneration = 0
    private var didAttemptRestore = false
    private var watcher: WorkspaceWatcher?

    static let recentBookmarksKey = "recentWorkspaceBookmarks"
    static let recentSearchesKey = "recentKnowledgeSearches"
    static let showHiddenFilesKey = "showHiddenFiles"
    static let maxRecents = 5
    static let maxRecentSearches = 10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showHiddenFiles = defaults.bool(forKey: Self.showHiddenFilesKey)
        recentWorkspaces = Self.resolveRecents(from: defaults)
        recentSearches = defaults.stringArray(forKey: Self.recentSearchesKey) ?? []
    }

    // MARK: - Opening

    func openWorkspace(at url: URL) async {
        // Keep security-scoped access for the workspace's lifetime; release the previous root.
        securityScopedRoot?.stopAccessingSecurityScopedResource()
        securityScopedRoot = url.startAccessingSecurityScopedResource() ? url : nil

        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        rootURL = root
        rootName = root.lastPathComponent
        settings = WorkspaceSettings.load(root: root, defaults: defaults)
        favoritePaths = Set((defaults.array(forKey: Self.favoritesKey(for: root)) as? [String]) ?? [])
        isLoading = true
        scanGeneration += 1
        let generation = scanGeneration

        recordRecent(url)

        let name = root.lastPathComponent
        let policy = WorkspaceScanPolicy(showHiddenFiles: showHiddenFiles)

        // Publish the root level first. A large vault can be navigated while
        // the complete recursive scan and knowledge rebuild continue.
        let initial = await Task.detached(priority: .userInitiated) {
            Self.scanRootLevel(root: root, rootName: name, policy: policy)
        }.value
        guard generation == scanGeneration else { return }
        folderTree = initial.folders
        documents = initial.documents

        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root, rootName: name, policy: policy)
        }.value

        // A stale scan must never clobber a workspace opened while it ran.
        guard generation == scanGeneration else { return }
        folderTree = snapshot.folders
        documents = snapshot.documents
        isLoading = false
        await rebuildIndex(generation: generation)

        watcher = WorkspaceWatcher(root: root) { [weak self] in
            Task { @MainActor in await self?.rescan() }
        }
    }

    /// Re-scan after filesystem changes (FSEvents). Inode identity keeps
    /// selection and open documents stable across external renames.
    func rescan() async {
        guard let rootURL, let rootName else { return }
        scanGeneration += 1
        let generation = scanGeneration
        let policy = WorkspaceScanPolicy(showHiddenFiles: showHiddenFiles)
        let snapshot = await Task.detached(priority: .utility) {
            Self.scan(root: rootURL, rootName: rootName, policy: policy)
        }.value
        if generation == scanGeneration {
            folderTree = snapshot.folders
            documents = Self.reconcileIdentities(old: documents, new: snapshot.documents)
            // Point open documents at their current path (external rename).
            for item in documents {
                if let document = session.openDocument(id: item.id),
                   document.fileURL?.path != item.url.path {
                    session.updateURL(id: item.id, to: item.url)
                }
            }
            await rebuildIndex(generation: generation)
        }
        // Outside the generation guard: reconciling open buffers is idempotent,
        // and a rescan discarded as stale (a watcher-triggered rescan racing a
        // manual one) must not skip it — the winner may already have run before
        // the change this rescan was reacting to.
        session.checkExternalChanges()
    }

    func setShowHiddenFiles(_ show: Bool) async {
        guard showHiddenFiles != show else { return }
        showHiddenFiles = show
        defaults.set(show, forKey: Self.showHiddenFilesKey)
        await rescan()
    }

    /// Rebuilds only changed index entries. Unchanged documents reuse their
    /// content and analysis, while deleted paths disappear with the new map.
    func rebuildIndex() async {
        await rebuildIndex(generation: scanGeneration)
    }

    private func rebuildIndex(generation: Int) async {
        let documents = documents
        let previous = knowledgeIndex
        isIndexing = true
        let rebuilt = await Task.detached(priority: .utility) {
            KnowledgeIndex.build(documents: documents, reusing: previous)
        }.value
        guard generation == scanGeneration else { return }
        knowledgeIndex = rebuilt
        knowledgeIndexRevision += 1
        isIndexing = false
    }

    func updateIndex(for item: DocumentItem, content: String) async {
        let analysis = await Task.detached(priority: .utility) {
            MarkiveCore.analyzeDocument(markdown: content)
        }.value
        guard let analysis,
              documents.contains(where: { $0.id == item.id }) else { return }
        var updated = knowledgeIndex
        updated.documentsByPath[item.relativePath] = IndexedDocument(
            id: item.id,
            diskID: item.diskID,
            relativePath: item.relativePath,
            title: item.title,
            modifiedAt: item.modifiedAt,
            content: content,
            analysis: analysis
        )
        knowledgeIndex = updated
        knowledgeIndexRevision += 1
    }

    /// Carries stable identities across a rescan. An unchanged or renamed file
    /// matches by inode; a safe-saved file (same path, replaced inode — every
    /// NSDocument autosave does this) matches by path.
    nonisolated static func reconcileIdentities(old: [DocumentItem], new: [DocumentItem]) -> [DocumentItem] {
        let oldByDiskID = Dictionary(old.map { ($0.diskID, $0) }, uniquingKeysWith: { a, _ in a })
        let oldByPath = Dictionary(old.map { ($0.relativePath, $0) }, uniquingKeysWith: { a, _ in a })
        let inodeMatchedIDs = Set(new.compactMap { oldByDiskID[$0.diskID]?.id })
        return new.map { item in
            var item = item
            if let match = oldByDiskID[item.diskID] {
                item.id = match.id
            } else if let previous = oldByPath[item.relativePath],
                      !inodeMatchedIDs.contains(previous.id) {
                item.id = previous.id
            }
            return item
        }
    }

    /// Reopen the most recent workspace on launch. No-op if a workspace is already
    /// open or restore already ran (multiple windows call this).
    func restoreMostRecentWorkspace() async {
        guard rootURL == nil, !didAttemptRestore else { return }
        didAttemptRestore = true
        guard let url = recentWorkspaces.first else { return }
        await openWorkspace(at: url)
    }

    // MARK: - Favorites

    nonisolated static func favoritesKey(for root: URL) -> String {
        "favorites:\(root.canonicalPath)"
    }

    var favoriteDocuments: [DocumentItem] {
        documents.filter { favoritePaths.contains($0.relativePath) }
    }

    func isFavorite(_ item: DocumentItem) -> Bool {
        favoritePaths.contains(item.relativePath)
    }

    func toggleFavorite(_ item: DocumentItem) {
        if favoritePaths.remove(item.relativePath) == nil {
            favoritePaths.insert(item.relativePath)
        }
        persistFavorites()
    }

    private func persistFavorites() {
        guard let rootURL else { return }
        defaults.set(favoritePaths.sorted(), forKey: Self.favoritesKey(for: rootURL))
    }

    // MARK: - Write operations

    enum WriteError: LocalizedError {
        case noWorkspace
        case invalidTitle
        case nameTaken(String)
        case outsideWorkspace
        case templateUnreadable(String)
        case linkedDocumentUnsaved(String)

        var errorDescription: String? {
            switch self {
            case .noWorkspace: "No workspace is open."
            case .invalidTitle: "Document names can't be empty or contain “/”."
            case .nameTaken(let name): "A file named “\(name)” already exists."
            case .outsideWorkspace: "The document path must stay inside the open workspace."
            case .templateUnreadable(let path): "The template “\(path)” could not be read."
            case .linkedDocumentUnsaved(let path):
                "Save “\(path)” before renaming this linked note."
            }
        }
    }

    /// Creates an empty numbered "Untitled" document and returns its item.
    func createDocument(inFolder relativeFolder: String?) throws -> DocumentItem {
        guard let rootURL else { throw WriteError.noWorkspace }
        let directory = relativeFolder.map { rootURL.appendingPathComponent($0, isDirectory: true) } ?? rootURL

        var title = "Untitled"
        var counter = 1
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(title).md").path) {
            counter += 1
            title = "Untitled \(counter)"
        }
        let url = directory.appendingPathComponent("\(title).md")
        try "".write(to: url, atomically: true, encoding: .utf8)

        guard let item = Self.item(at: url, root: rootURL, rootName: rootName ?? "") else {
            throw CocoaError(.fileReadUnknown)
        }
        documents.insert(item, at: 0)
        return item
    }

    /// Creates a specifically named document, including intermediate folders.
    /// Existing files are returned unchanged and never overwritten.
    func createDocument(relativePath: String, content: String = "") throws -> (DocumentItem, created: Bool) {
        guard let rootURL else { throw WriteError.noWorkspace }
        var path = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.hasPrefix("/") else { throw WriteError.invalidTitle }
        if !WorkspaceStore.markdownExtensions.contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        ) {
            path += ".md"
        }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else { throw WriteError.outsideWorkspace }
            components.append(component)
        }
        let normalized = components.joined(separator: "/")
        guard !normalized.isEmpty else { throw WriteError.invalidTitle }
        let url = rootURL.appendingPathComponent(normalized)
        guard url.canonicalPath.hasPrefix(rootURL.canonicalPath + "/") else {
            throw WriteError.outsideWorkspace
        }

        if FileManager.default.fileExists(atPath: url.path) {
            guard let item = Self.item(at: url, root: rootURL, rootName: rootName ?? "") else {
                throw CocoaError(.fileReadUnknown)
            }
            return (item, false)
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        guard let item = Self.item(at: url, root: rootURL, rootName: rootName ?? "") else {
            throw CocoaError(.fileReadUnknown)
        }
        documents.insert(item, at: 0)
        return (item, true)
    }

    func createDailyDocument(on date: Date = Date()) throws -> (DocumentItem, created: Bool) {
        guard let rootURL else { throw WriteError.noWorkspace }
        let relativePath = settings.dailyRelativePath(on: date)
        let title = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        var content = ""
        if !settings.dailyTemplate.isEmpty {
            let configured = rootURL.appendingPathComponent(settings.dailyTemplate)
            let templateURL = FileManager.default.fileExists(atPath: configured.path)
                ? configured
                : configured.appendingPathExtension("md")
            guard let template = try? String(contentsOf: templateURL, encoding: .utf8) else {
                throw WriteError.templateUnreadable(settings.dailyTemplate)
            }
            content = WorkspaceSettings.expandTemplate(template, title: title, date: date)
        }
        return try createDocument(relativePath: relativePath, content: content)
    }

    func templateDocuments() -> [DocumentItem] {
        guard !settings.templatesFolder.isEmpty else { return [] }
        return documents.filter {
            $0.relativeFolder == settings.templatesFolder
                || $0.relativeFolder.hasPrefix(settings.templatesFolder + "/")
        }
    }

    func contentFromTemplate(_ template: DocumentItem, title: String, date: Date = Date()) throws -> String {
        guard let content = try? String(contentsOf: template.url, encoding: .utf8) else {
            throw WriteError.templateUnreadable(template.relativePath)
        }
        return WorkspaceSettings.expandTemplate(content, title: title, date: date)
    }

    func saveSettings() {
        guard let rootURL else { return }
        settings.save(root: rootURL, defaults: defaults)
    }

    func recordSearch(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        recentSearches.insert(query, at: 0)
        recentSearches = Array(recentSearches.prefix(Self.maxRecentSearches))
        defaults.set(recentSearches, forKey: Self.recentSearchesKey)
    }

    /// Renames the file in place; identity (inode) is unchanged, so selection
    /// and history keep working. The extension is preserved.
    func rename(
        _ item: DocumentItem,
        to newTitle: String,
        updateInboundLinks: Bool? = nil
    ) throws -> DocumentItem {
        guard let rootURL else { throw WriteError.noWorkspace }
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !title.contains("/") else { throw WriteError.invalidTitle }
        guard title != item.title else { return item }

        let newURL = item.url.deletingLastPathComponent()
            .appendingPathComponent(title)
            .appendingPathExtension(item.url.pathExtension)
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            throw WriteError.nameTaken(newURL.lastPathComponent)
        }
        let newRelativePath = [item.relativeFolder, newURL.lastPathComponent]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let rewrites = (updateInboundLinks ?? settings.alwaysUpdateLinks)
            ? knowledgeIndex.rewritingInboundLinks(
                from: item.relativePath,
                to: newRelativePath
            )
            : [:]
        for sourcePath in rewrites.keys {
            guard let sourceItem = documents.first(where: { $0.relativePath == sourcePath }),
                  let open = session.openDocument(id: sourceItem.id) else { continue }
            if open.hasUnautosavedChanges {
                throw WriteError.linkedDocumentUnsaved(sourcePath)
            }
        }

        var originals: [String: Data] = [:]
        for sourcePath in rewrites.keys {
            let sourceURL = sourcePath == item.relativePath
                ? item.url
                : rootURL.appendingPathComponent(sourcePath)
            originals[sourcePath] = try Data(contentsOf: sourceURL)
        }

        try FileManager.default.moveItem(at: item.url, to: newURL)
        do {
            for (sourcePath, content) in rewrites {
                let sourceURL = sourcePath == item.relativePath
                    ? newURL
                    : rootURL.appendingPathComponent(sourcePath)
                try Data(content.utf8).write(to: sourceURL, options: .atomic)
            }
        } catch {
            for (sourcePath, data) in originals {
                let sourceURL = sourcePath == item.relativePath
                    ? newURL
                    : rootURL.appendingPathComponent(sourcePath)
                try? data.write(to: sourceURL, options: .atomic)
            }
            try? FileManager.default.moveItem(at: newURL, to: item.url)
            throw error
        }

        session.updateURL(id: item.id, to: newURL)

        guard var updated = Self.item(at: newURL, root: rootURL, rootName: rootName ?? "") else {
            throw CocoaError(.fileReadUnknown)
        }
        // The stable identity carries over; only the disk inode is re-read.
        updated.id = item.id
        if let index = documents.firstIndex(where: { $0.id == item.id }) {
            documents[index] = updated
        }
        if favoritePaths.remove(item.relativePath) != nil {
            favoritePaths.insert(updated.relativePath)
            persistFavorites()
        }
        for sourcePath in rewrites.keys {
            guard let sourceItem = documents.first(where: {
                $0.relativePath == sourcePath || (
                    sourcePath == item.relativePath && $0.id == item.id
                )
            }),
            let open = session.openDocument(id: sourceItem.id) else { continue }
            let url = sourcePath == item.relativePath
                ? newURL
                : rootURL.appendingPathComponent(sourcePath)
            try? open.revert(toContentsOf: url, ofType: MarkdownDocument.markdownType)
        }
        return updated
    }

    /// Moves the file to the Trash and forgets it. Returns the trashed URL.
    @discardableResult
    func trash(_ item: DocumentItem) throws -> URL? {
        session.closeDiscarding(id: item.id)
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashedURL)
        documents.removeAll { $0.id == item.id }
        if favoritePaths.remove(item.relativePath) != nil {
            persistFavorites()
        }
        return trashedURL as URL?
    }

    /// Builds a DocumentItem from a file on disk. Nil if the file vanished.
    nonisolated static func item(at url: URL, root: URL, rootName: String) -> DocumentItem? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.canonicalPath
        guard resolved.path.hasPrefix(rootPath + "/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.path),
              let device = attributes[.systemNumber] as? Int,
              let inode = attributes[.systemFileNumber] as? Int else { return nil }
        let relativePath = String(resolved.path.dropFirst(rootPath.count + 1))
        let relativeFolder = relativePath.contains("/")
            ? String(relativePath.prefix(upTo: relativePath.lastIndex(of: "/")!))
            : ""
        return DocumentItem(
            id: FileID(device: device, inode: inode),
            diskID: FileID(device: device, inode: inode),
            url: resolved,
            title: resolved.deletingPathExtension().lastPathComponent,
            relativePath: relativePath,
            relativeFolder: relativeFolder,
            folderLabel: relativeFolder.isEmpty ? rootName : relativeFolder,
            modifiedAt: attributes[.modificationDate] as? Date ?? .distantPast,
            createdAt: attributes[.creationDate] as? Date ?? .distantPast
        )
    }

    // MARK: - Recents

    private func recordRecent(_ url: URL) {
        guard let bookmark = Self.bookmarkData(for: url) else { return }
        var bookmarks = (defaults.array(forKey: Self.recentBookmarksKey) as? [Data]) ?? []
        // Dedup by canonical path, newest first.
        let canonicalPath = url.canonicalPath
        bookmarks = bookmarks.filter { Self.resolveBookmark($0)?.canonicalPath != canonicalPath }
        bookmarks.insert(bookmark, at: 0)
        bookmarks = Array(bookmarks.prefix(Self.maxRecents))
        defaults.set(bookmarks, forKey: Self.recentBookmarksKey)
        recentWorkspaces = Self.resolveRecents(from: defaults)
    }

    private static func resolveRecents(from defaults: UserDefaults) -> [URL] {
        let bookmarks = (defaults.array(forKey: recentBookmarksKey) as? [Data]) ?? []
        return bookmarks.compactMap(resolveBookmark)
    }

    // Security-scoped bookmarks need the sandbox entitlement; dev builds run
    // unsandboxed, so fall back to plain bookmarks there. Storing scoped ones
    // now means recents survive turning the sandbox on later.
    nonisolated private static func bookmarkData(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope) {
            return scoped
        }
        return try? url.bookmarkData()
    }

    nonisolated private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            bookmarkDataIsStale: &stale
        ) {
            return url
        }
        return try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
    }

    // MARK: - Scanning

    struct Snapshot: Sendable {
        var folders: [FolderNode] = []
        var documents: [DocumentItem] = []
    }

    nonisolated static let markdownExtensions: Set<String> = ["md", "markdown"]

    /// Reads only the root directory so the explorer has useful navigation
    /// before a recursive scan of a large vault completes.
    nonisolated static func scanRootLevel(
        root: URL,
        rootName: String,
        policy: WorkspaceScanPolicy = WorkspaceScanPolicy()
    ) -> Snapshot {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return Snapshot() }

        var folders: [String] = []
        var documents: [DocumentItem] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard !policy.ignores(url, isDirectory: isDirectory) else { continue }
            if isDirectory {
                folders.append(url.lastPathComponent)
            } else if let item = scannableItem(at: url, root: root, rootName: rootName) {
                documents.append(item)
            }
        }
        return Snapshot(
            folders: buildTree(from: folders.sorted()),
            documents: documents
        )
    }

    /// Walks the root collecting Markdown files and the folder tree. Ignore
    /// rules are centralized in `WorkspaceScanPolicy`. Package contents and
    /// symlinked directories are not traversed, so loops cannot occur.
    nonisolated static func scan(
        root: URL,
        rootName: String,
        policy: WorkspaceScanPolicy = WorkspaceScanPolicy()
    ) -> Snapshot {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return Snapshot() }

        let rootPath = root.path
        var folderPaths: [String] = []
        var documents: [DocumentItem] = []

        for case let url as URL in enumerator {
            let resolved = url.standardizedFileURL
            let path = resolved.path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(path.dropFirst(rootPath.count + 1))

            let isDirectory = (try? resolved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if policy.ignores(resolved, isDirectory: isDirectory) {
                if isDirectory { enumerator.skipDescendants() }
                continue
            }
            if isDirectory {
                folderPaths.append(relativePath)
                continue
            }

            if let item = scannableItem(at: resolved, root: root, rootName: rootName) {
                documents.append(item)
            }
        }

        return Snapshot(
            folders: buildTree(from: folderPaths.sorted()),
            documents: documents
        )
    }

    nonisolated private static func scannableItem(
        at url: URL,
        root: URL,
        rootName: String
    ) -> DocumentItem? {
        guard markdownExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        // Skip "name~.md" backups: NSDocument's safe-save briefly renames the
        // original file to one, and scanning it steals the document identity.
        guard !url.deletingPathExtension().lastPathComponent.hasSuffix("~") else { return nil }
        return item(at: url, root: root, rootName: rootName)
    }

    /// Builds a nested tree from sorted relative folder paths.
    nonisolated static func buildTree(from sortedPaths: [String]) -> [FolderNode] {
        var roots: [FolderNode] = []
        for path in sortedPaths {
            insert(path: path, components: path.split(separator: "/").map(String.init), into: &roots, prefix: "")
        }
        return roots
    }

    nonisolated private static func insert(
        path: String,
        components: [String],
        into nodes: inout [FolderNode],
        prefix: String
    ) {
        guard let head = components.first else { return }
        let id = prefix.isEmpty ? head : "\(prefix)/\(head)"
        let rest = Array(components.dropFirst())
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            if !rest.isEmpty {
                var children = nodes[index].children ?? []
                insert(path: path, components: rest, into: &children, prefix: id)
                nodes[index].children = children
            }
        } else {
            var node = FolderNode(id: id, name: head, children: nil)
            if !rest.isEmpty {
                var children: [FolderNode] = []
                insert(path: path, components: rest, into: &children, prefix: id)
                node.children = children
            }
            nodes.append(node)
        }
    }
}
