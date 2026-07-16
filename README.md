<p align="center">
  <img src="./markive-icon.svg" width="128" alt="Markive app icon">
</p>

# Markive

> macOS opens PDFs in Preview.
> Markdown deserves the same: double-click, read, done.

A native macOS Markdown viewer and editor. Open a `.md` from Finder and it renders. Hit ⌘2 and it's an editor. Open a folder and it becomes a root — no project setup, no workspace file, no Electron.

## What it is

- **Viewer first.** Rendered, Source, and Split views (⌘1/⌘2/⌘3). GitHub-style heading anchors, tables, task lists, fenced code. Local images and relative links resolve — including images written as raw HTML, the way READMEs do it.
- **Editor when you need it.** CodeMirror with Markdown highlighting, multi-cursor (⌘-click), undo history, live re-render in Split mode.
- **Folder explorer.** Open a folder as a root and browse it in a sidebar — lazy tree, Markdown-focused (folders and `.md` files only), hidden files toggle, unsaved-changes indicator, and safe against symlink loops.
- **Tabs.** Open several documents at once, each keeping its own content, path, view mode, selection, and dirty state. Reorder by dragging, close individually, and picking an already-open file focuses its tab instead of duplicating it.
- **Safe by default.** Rendered HTML is sanitized; the webview never navigates. External links open in your browser, local `.md` links open in Markive, everything else is blocked. Saves are atomic — a failed write leaves the original untouched.
- **Lossless quit.** ⌘Q never nags. The session — window, document, view mode, scroll, and unsaved edits — restores on the next launch, like TextEdit.
- **Aware of the disk.** External edits reload clean documents automatically; conflicting edits raise a banner instead of silently losing either side.
- **Native.** Real menu bar, light/dark/system appearance, Finder file associations, drag & drop, clipboard paste (text or copied files).

## Requirements

macOS 10.13+ on Apple Silicon or Intel — the bundle is universal.

## Install

Grab the latest `.dmg` from [Releases](https://github.com/dariuscorvus/markive/releases), open it, and drag Markive to Applications.

Markive is unsigned. macOS quarantines web downloads, and for an unsigned app that shows up as **"Markive is damaged and can't be opened"**. It isn't. Clear the flag once:

```bash
xattr -dr com.apple.quarantine /Applications/Markive.app
```

### Build from source

```bash
npm install
npm run tauri build -- --target universal-apple-darwin
ditto target/universal-apple-darwin/release/bundle/macos/Markive.app /Applications/Markive.app
```

## Command line

Settings (⌘,) → **Install Command Line Tool** puts `markive` on your PATH. Then:

```
markive notes.md              # open a file in the app
markive notes/                # open a folder as a root
markive -                     # read a document from stdin
markive render notes.md       # print sanitized HTML to stdout
echo '# hi' | markive render  # works in pipes
markive --version
```

`render` is a plain Unix filter — no window, no daemon, exits when done. Opening a file or folder hands off to the running instance and returns.

## Keyboard

| | |
|---|---|
| ⌘O / ⇧⌘O / ⌘N / ⌘S / ⇧⌘S | Open, Open Folder, New, Save, Save As |
| ⌘W / ⇧⌘W | Close Tab, Close Window |
| ⌘1 / ⌘2 / ⌘3 | Rendered, Source, Split |
| ⌘E | Cycle view mode |
| ⌘F, ⌘G / ⇧⌘G | Find, next / previous match |
| ⌘V | Paste clipboard as document (outside the editor) |
| ⌘, | Settings — appearance, prose width, editor font size, line wrap |

## Architecture

A Rust workspace with the logic where it can be tested and the shell kept thin:

- `crates/markive-core` — parsing (pulldown-cmark), sanitizing (ammonia), path resolution, atomic saves. Pure functions, no Tauri types, `#![forbid(unsafe_code)]`.
- `src-tauri` — the Tauri 2 shell: commands, window, menus, file watching, single-instance forwarding, CLI entry point.
- `src` — Svelte 5 frontend, one window.

Rendering large documents is held to a measured budget: the test suite generates 1, 5, and 20 MB fixtures, records timings, and bounds memory across repeated renders.

```bash
cargo test --workspace   # core, CLI, lifecycle, perf
npm test                 # frontend logic
npm run tauri dev
```

MIT — see [LICENSE](LICENSE).

---

[darius.codes](https://darius.codes)
