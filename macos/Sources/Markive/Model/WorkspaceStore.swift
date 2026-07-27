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
    private(set) var recentWorkspaces: [URL] = []

    /// Open NSDocuments, shared across windows.
    let session = DocumentSession()

    private let defaults: UserDefaults
    private var securityScopedRoot: URL?
    private var scanGeneration = 0
    private var didAttemptRestore = false
    private var watcher: WorkspaceWatcher?

    static let recentBookmarksKey = "recentWorkspaceBookmarks"
    static let maxRecents = 5

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentWorkspaces = Self.resolveRecents(from: defaults)
    }

    // MARK: - Opening

    func openWorkspace(at url: URL) async {
        // Keep security-scoped access for the workspace's lifetime; release the previous root.
        securityScopedRoot?.stopAccessingSecurityScopedResource()
        securityScopedRoot = url.startAccessingSecurityScopedResource() ? url : nil

        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        rootURL = root
        rootName = root.lastPathComponent
        isLoading = true
        scanGeneration += 1
        let generation = scanGeneration

        recordRecent(url)

        let name = root.lastPathComponent
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root, rootName: name)
        }.value

        // A stale scan must never clobber a workspace opened while it ran.
        guard generation == scanGeneration else { return }
        folderTree = snapshot.folders
        documents = snapshot.documents
        isLoading = false

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
        let snapshot = await Task.detached(priority: .utility) {
            Self.scan(root: rootURL, rootName: rootName)
        }.value
        guard generation == scanGeneration else { return }
        folderTree = snapshot.folders
        documents = snapshot.documents
    }

    /// Reopen the most recent workspace on launch. No-op if a workspace is already
    /// open or restore already ran (multiple windows call this).
    func restoreMostRecentWorkspace() async {
        guard rootURL == nil, !didAttemptRestore else { return }
        didAttemptRestore = true
        guard let url = recentWorkspaces.first else { return }
        await openWorkspace(at: url)
    }

    // MARK: - Write operations

    enum WriteError: LocalizedError {
        case noWorkspace
        case invalidTitle
        case nameTaken(String)

        var errorDescription: String? {
            switch self {
            case .noWorkspace: "No workspace is open."
            case .invalidTitle: "Document names can't be empty or contain “/”."
            case .nameTaken(let name): "A file named “\(name)” already exists."
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

    /// Renames the file in place; identity (inode) is unchanged, so selection
    /// and history keep working. The extension is preserved.
    func rename(_ item: DocumentItem, to newTitle: String) throws -> DocumentItem {
        let title = newTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, !title.contains("/") else { throw WriteError.invalidTitle }
        guard title != item.title else { return item }

        let newURL = item.url.deletingLastPathComponent()
            .appendingPathComponent(title)
            .appendingPathExtension(item.url.pathExtension)
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            throw WriteError.nameTaken(newURL.lastPathComponent)
        }
        try FileManager.default.moveItem(at: item.url, to: newURL)
        session.updateURL(id: item.id, to: newURL)

        guard let rootURL,
              let updated = Self.item(at: newURL, root: rootURL, rootName: rootName ?? "") else {
            throw CocoaError(.fileReadUnknown)
        }
        if let index = documents.firstIndex(where: { $0.id == item.id }) {
            documents[index] = updated
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

    /// Walks the root collecting Markdown files and the folder tree. Hidden files
    /// and package contents are skipped. `DirectoryEnumerator` does not descend
    /// into symlinked directories, so symlink loops cannot occur.
    nonisolated static func scan(root: URL, rootName: String) -> Snapshot {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
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
            if isDirectory {
                folderPaths.append(relativePath)
                continue
            }

            guard markdownExtensions.contains(resolved.pathExtension.lowercased()) else { continue }
            if let item = item(at: resolved, root: root, rootName: rootName) {
                documents.append(item)
            }
        }

        return Snapshot(
            folders: buildTree(from: folderPaths.sorted()),
            documents: documents
        )
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
