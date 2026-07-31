# Changelog

All notable changes to Markive are documented here.

## [Unreleased]

## [0.3.1] - 2026-07-31

### Fixed

- Hidden trailing block IDs in rendered previews while preserving them in Markdown source and block embeds.

## [0.3.0] - 2026-07-31

### Added

- Side-by-side document views with independent selection, scroll position, presentation state, link navigation, and session restoration.
- Folder creation and rename, file moves, and drag-to-folder actions with conflict checks and link updates.
- Inline rendering for image, Markdown file, heading, and block embeds with bounded recursion and visible failure states.
- Footnote references, definitions, distinct backlinks, unresolved states, and keyboard navigation.
- Offline inline and block math rendering with source-preserving copy and visible errors for invalid expressions.

### Changed

- Large workspaces can be navigated before a complete recursive scan finishes.
- Hidden-file and ignore behavior is shared by the explorer, Quick Open, search, and the knowledge index.
- Empty folders and modified-file state are visible in the explorer.

## [0.2.0] - 2026-07-30

### Added

- A native SwiftUI workspace with a folder tree, All Documents, Recent, Favorites, Quick Open, history navigation, and Finder integration.
- Workspace-wide content search with context, phrases, case matching, exclusions, tags, properties, and source selection.
- An in-memory knowledge index for headings, Markdown links, wikilinks, aliases, YAML frontmatter, tags, and tasks.
- Wikilink completion, heading links, backlinks, outgoing-link states, and atomic inbound-link updates when a note is renamed.
- Properties, tags, backlinks, outgoing links, and file information in the inspector.
- Daily notes, a configurable capture folder, static templates, Home, and read-only support for compatible Obsidian settings.
- Obsidian-style callouts with custom titles and foldable sections.
- Read-only rendering for the Dataview `TABLE` and `LIST` queries used by home and hub notes.
- A TextKit 2 editor with Markdown syntax highlighting, list continuation, and indentation.
- Syntax-highlighted fenced code and Mermaid diagrams with native styling.
- A universal sandboxed DMG for Apple Silicon and Intel Macs.

### Changed

- The native SwiftUI app replaces the Tauri/Svelte app.
- Finder-opened files now open directly in rendered view and can expand into their containing workspace.
- YAML frontmatter stays in the Markdown source but is hidden in reading view.
- The preview and editor now keep the current document synchronized during fast document changes.

### Fixed

- Fixed stale or previous-document content appearing in the preview.
- Fixed standalone Finder-open under the App Sandbox.
- Fixed syntax-highlighting artifacts during scrolling, editing, and relayout.
- Fixed blank previews in sandboxed release builds.

## [0.1.2] - 2026-07-27

### Added

- The first native SwiftUI prototype with disk-backed workspaces, editing, autosave, file watching, Favorites, Markdown rendering through the Rust core, and live preview.
- A bottom status bar and multi-file paste into tabs.

### Fixed

- Refreshed the Explorer after external filesystem changes.
- Fixed an infinite loading state when expanding an Explorer folder.
- Expanded sanitized HTML support for structural elements.

## [0.1.1] - 2026-07-19

### Added

- Folder roots, the Explorer, tabs, file operations, Quick Open, search, and Favorites.

### Fixed

- Fixed the web view not filling its window after geometry restoration.

## [0.1.0] - 2026-07-16

### Added

- The first Markive release: a Markdown viewer and editor for macOS.
- Finder open, drag and drop, local images and links, source and rendered views, atomic saving, external-change handling, native menus, appearance settings, session restoration, accessibility coverage, the command-line tool, and universal DMG packaging.

[Unreleased]: https://github.com/dariuscorvus/markive/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/dariuscorvus/markive/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/dariuscorvus/markive/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dariuscorvus/markive/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/dariuscorvus/markive/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/dariuscorvus/markive/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/dariuscorvus/markive/releases/tag/v0.1.0
