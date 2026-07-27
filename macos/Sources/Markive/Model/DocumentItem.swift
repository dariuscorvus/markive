import Foundation

/// Identity that survives rename and move — device + inode, not path.
struct FileID: Hashable, Sendable {
    var device: Int
    var inode: Int
}

struct DocumentItem: Identifiable, Hashable, Sendable {
    let id: FileID
    var url: URL
    /// Filename without the Markdown extension.
    var title: String
    /// Path relative to the workspace root, e.g. "Notes/Projects/Roadmap.md".
    var relativePath: String
    /// Containing folder relative to the root; empty string for root-level files.
    var relativeFolder: String
    /// What the UI shows as the location — the folder, or the workspace name for root-level files.
    var folderLabel: String
    var modifiedAt: Date
    var createdAt: Date
}

struct FolderNode: Identifiable, Hashable, Sendable {
    /// Folder path relative to the workspace root, e.g. "Notes/Projects".
    let id: String
    var name: String
    var children: [FolderNode]?
}

extension URL {
    /// Path with symlinks resolved — "/var/…" and "/private/var/…" compare equal.
    var canonicalPath: String {
        standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum DocumentLoadFailure: Error, Hashable {
    /// The file disappeared between enumeration and read.
    case missing
    /// The file exists but is not decodable as UTF-8 text.
    case unreadable
}

enum SavedSearch: String, CaseIterable, Hashable, Identifiable {
    case modifiedToday = "Modified Today"

    var id: Self { self }
    var systemImage: String { "calendar.badge.clock" }
}
