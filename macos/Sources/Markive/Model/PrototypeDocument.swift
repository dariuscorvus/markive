import Foundation

enum DocumentStatus: Hashable {
    case ok
    case missing
    case unreadable
    case externallyChanged
}

enum DocumentLocation: String, CaseIterable, Hashable, Identifiable {
    case onMyMac = "On My Mac"
    case iCloudDrive = "iCloud Drive"
    case externalFolders = "External Folders"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .onMyMac: "desktopcomputer"
        case .iCloudDrive: "icloud"
        case .externalFolders: "externaldrive"
        }
    }
}

enum SavedSearch: String, CaseIterable, Hashable, Identifiable {
    case modifiedToday = "Modified Today"
    case unlinkedNotes = "Unlinked Notes"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .modifiedToday: "calendar.badge.clock"
        case .unlinkedNotes: "link"
        }
    }
}

struct PrototypeDocument: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var folder: String
    var location: DocumentLocation = .onMyMac
    var modifiedAt: Date
    var createdAt: Date
    var isFavorite: Bool = false
    var tags: [String] = []
    var status: DocumentStatus = .ok
    var content: String

    var path: String { "\(folder)/\(title).md" }

    var wordCount: Int {
        content.split(whereSeparator: \.isWhitespace).count
    }

    var characterCount: Int { content.count }

    var isUnlinked: Bool { !content.contains("[[") }
}

struct PrototypeFolder: Identifiable, Hashable {
    /// Folder path relative to the workspace root, e.g. "Notes/Projects".
    let id: String
    var name: String
    var children: [PrototypeFolder]?
}
