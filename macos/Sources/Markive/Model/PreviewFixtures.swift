import Foundation

/// Writes a small real workspace to a temp directory for previews and dev runs.
/// Honest fixtures instead of a faked filesystem seam.
enum PreviewFixtures {
    /// Isolated defaults so previews never touch the real recents list.
    static func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "markive.preview.\(UUID().uuidString)")!
        suite.removePersistentDomain(forName: suite.description)
        return suite
    }

    static func workspaceURL() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkivePreviewWorkspace", isDirectory: true)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: root.path) {
            return root
        }
        let files: [(String, String)] = [
            ("Roadmap.md", "# Roadmap\n\nThe native shell ships in stages.\n\n- [x] Window structure\n- [ ] Filesystem layer\n"),
            ("Notes/Ideas.md", "# Ideas\n\nPreview should reuse the sanitizer pipeline.\n"),
            ("Notes/Projects/Editor Spike.md", "# Editor Spike\n\nTextKit 2 against the 20 MB fixture.\n"),
            ("Journal/2026-07-27.md", "# 2026-07-27\n\nStarted the filesystem layer.\n"),
            ("Reading/Reading List.md", "# Reading List\n\n- The Mythical Man-Month\n"),
        ]
        for (path, content) in files {
            let url = root.appendingPathComponent(path)
            try? fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
}
