#![forbid(unsafe_code)]

pub mod cli;

use std::sync::Mutex;

/// What the process was asked to show at startup.
pub enum Launch {
    /// An empty window.
    Window,
    /// A validated, absolute document path.
    Document(String),
    /// A validated, absolute folder path, opened as a filesystem root.
    Folder(String),
    /// A temporary file holding piped stdin, deleted after reading.
    StdinFile(String),
}

/// A document or folder open request delivered to the frontend: at
/// startup through the `launch_document` command, afterwards as an
/// `open-document` event.
#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenRequest {
    path: Option<String>,
    folder_path: Option<String>,
    stdin_path: Option<String>,
    error: Option<String>,
}

impl OpenRequest {
    fn from_launch(launch: Launch) -> Option<Self> {
        match launch {
            Launch::Window => None,
            Launch::Document(path) => Some(Self {
                path: Some(path),
                folder_path: None,
                stdin_path: None,
                error: None,
            }),
            Launch::Folder(path) => Some(Self {
                path: None,
                folder_path: Some(path),
                stdin_path: None,
                error: None,
            }),
            Launch::StdinFile(file) => Some(Self {
                path: None,
                folder_path: None,
                stdin_path: Some(file),
                error: None,
            }),
        }
    }

    /// Interprets the arguments a second instance was started with —
    /// the same protocol `main` produces: nothing, one absolute path,
    /// or `--stdin-file <path>`.
    fn from_forwarded_args(args: &[String]) -> Option<Self> {
        match args {
            [flag, file] if flag == "--stdin-file" => Some(Self {
                path: None,
                folder_path: None,
                stdin_path: Some(file.clone()),
                error: None,
            }),
            [path] => Some(request_for_path(path)),
            _ => None,
        }
    }
}

/// Decides whether `path` names a Markdown document or a folder root,
/// then validates it into an open request. Shared by single-instance
/// argument forwarding and macOS open-file events.
fn request_for_path(path: &str) -> OpenRequest {
    if std::path::Path::new(path).is_dir() {
        match cli::validate_folder_path(path) {
            Ok(()) => OpenRequest {
                path: None,
                folder_path: Some(path.to_string()),
                stdin_path: None,
                error: None,
            },
            Err(error) => OpenRequest {
                path: None,
                folder_path: None,
                stdin_path: None,
                error: Some(error),
            },
        }
    } else {
        match cli::validate_document_path(path) {
            Ok(()) => OpenRequest {
                path: Some(path.to_string()),
                folder_path: None,
                stdin_path: None,
                error: None,
            },
            Err(error) => OpenRequest {
                path: None,
                folder_path: None,
                stdin_path: None,
                error: Some(error),
            },
        }
    }
}

/// Holds open requests that arrive before the frontend is ready — the
/// command-line path and macOS open-file events during a cold launch.
struct LaunchState {
    pending: Option<OpenRequest>,
    frontend_ready: bool,
}

#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
fn launch_document(state: tauri::State<'_, Mutex<LaunchState>>) -> Option<OpenRequest> {
    let mut state = state.lock().expect("launch state lock poisoned");
    state.frontend_ready = true;
    state.pending.take()
}

/// Converts a URL from a macOS open-file event into a filesystem path,
/// without judging whether it names a file or a folder.
#[cfg(target_os = "macos")]
fn file_url_to_path(url: &tauri::Url) -> Result<String, String> {
    url.to_file_path()
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|()| format!("{url} is not a file path"))
}

/// Converts a URL from a macOS open-file event into an open request,
/// routing it to the document or folder branch depending on what it
/// names on disk.
#[cfg(target_os = "macos")]
fn open_request_from_url(url: &tauri::Url) -> OpenRequest {
    match file_url_to_path(url) {
        Ok(path) => request_for_path(&path),
        Err(error) => OpenRequest {
            path: None,
            folder_path: None,
            stdin_path: None,
            error: Some(error),
        },
    }
}

/// Hands an open request to the frontend, or stores it for the startup
/// `launch_document` fetch when the frontend has not loaded yet.
fn deliver_open_request(app: &tauri::AppHandle, request: OpenRequest) {
    use tauri::{Emitter, Manager};

    let state = app.state::<Mutex<LaunchState>>();
    let mut state = state.lock().expect("launch state lock poisoned");

    if state.frontend_ready {
        drop(state);
        if let Err(error) = app.emit("open-document", request) {
            eprintln!("markive: failed to deliver open-document event: {error}");
        }
    } else {
        state.pending = Some(request);
    }
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenedDocument {
    path: String,
    html: String,
    content: String,
}

/// Grants the asset protocol access to exactly the images a rendered
/// document references. A failed grant leaves that image broken in the
/// view; it should not fail rendering.
fn grant_image_access(app: &tauri::AppHandle, rendered: &markive_core::RenderedDocument) {
    use tauri::Manager;

    let scope = app.asset_protocol_scope();
    for image in rendered.local_images() {
        let _ = scope.allow_file(image);
    }
}

#[tauri::command]
async fn open_document(app: tauri::AppHandle, path: String) -> Result<OpenedDocument, String> {
    let document = markive_core::open_document(&path)
        .map_err(|error| format!("Unable to read {path}: {error}"))?;

    // Canonicalize so relative launch paths (`markive notes.md`) get a
    // real base directory for image resolution.
    let canonical = std::fs::canonicalize(document.path())
        .map_err(|error| format!("Unable to resolve {path}: {error}"))?;
    let base_dir = canonical
        .parent()
        .ok_or_else(|| format!("{path} has no parent directory"))?;

    let rendered = markive_core::render_document(document.content(), Some(base_dir));
    grant_image_access(&app, &rendered);

    Ok(OpenedDocument {
        path: canonical.to_string_lossy().into_owned(),
        html: rendered.html().to_owned(),
        content: document.content().to_owned(),
    })
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenedFolder {
    path: String,
}

/// Opens a folder as a filesystem root: validates it exists and
/// resolves it to an absolute path. Markive writes nothing inside
/// it — the root only ever lives in memory and in the session file
/// under the app's own data directory.
#[tauri::command]
async fn open_folder(path: String) -> Result<OpenedFolder, String> {
    let absolute = cli::absolute_folder_path(&path)?;
    Ok(OpenedFolder { path: absolute })
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FolderEntry {
    name: String,
    path: String,
    is_dir: bool,
    is_symlink: bool,
}

/// Lists one directory level: every subfolder plus every Markdown
/// file, sorted folders-first then case-insensitively by name.
///
/// Hidden entries (dotfiles) are included — the frontend decides
/// whether to display them, so toggling that setting never needs a
/// re-read. Non-Markdown files are dropped entirely; the explorer
/// only ever shows folders and documents it can open.
///
/// Each entry's `path` is canonicalized, including through symlinks,
/// so a symlinked folder resolves to its real target. The caller
/// compares that canonical path against the chain of folders already
/// expanded above it to detect a symlink cycle before ever
/// expanding into it — this function only ever reads one level and
/// never recurses, so it cannot loop on its own.
///
/// An entry that fails to stat (a broken symlink, a permission
/// error on that one entry) is skipped rather than failing the
/// whole listing.
///
/// # Errors
///
/// Returns a message suitable for display when `path` itself cannot
/// be read (missing, not a directory, no permission).
fn list_folder_entries(path: &std::path::Path) -> Result<Vec<FolderEntry>, String> {
    let read_dir = std::fs::read_dir(path)
        .map_err(|error| format!("Unable to read {}: {error}", path.display()))?;

    let mut entries = Vec::new();
    for entry in read_dir.flatten() {
        let entry_path = entry.path();

        let Ok(metadata) = std::fs::metadata(&entry_path) else {
            continue;
        };
        let is_dir = metadata.is_dir();
        if !is_dir && !markive_core::is_markdown_path(&entry_path) {
            continue;
        }

        let is_symlink = std::fs::symlink_metadata(&entry_path)
            .is_ok_and(|metadata| metadata.file_type().is_symlink());
        let Ok(canonical) = std::fs::canonicalize(&entry_path) else {
            continue;
        };

        entries.push(FolderEntry {
            name: entry.file_name().to_string_lossy().into_owned(),
            path: canonical.to_string_lossy().into_owned(),
            is_dir,
            is_symlink,
        });
    }

    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(entries)
}

#[tauri::command]
async fn read_folder_entries(path: String) -> Result<Vec<FolderEntry>, String> {
    list_folder_entries(std::path::Path::new(&path))
}

#[cfg(test)]
mod folder_entry_tests {
    use super::list_folder_entries;

    struct TestDir(std::path::PathBuf);

    impl TestDir {
        fn new(name: &str) -> Self {
            let dir = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
            std::fs::create_dir_all(&dir).expect("create test dir");
            Self(dir)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn lists_folders_and_markdown_files_only() {
        let dir = TestDir::new("markive-list-filter");
        std::fs::create_dir(dir.0.join("subfolder")).expect("create subfolder");
        std::fs::write(dir.0.join("notes.md"), "# hi").expect("write markdown");
        std::fs::write(dir.0.join("image.png"), "not markdown").expect("write image");

        let entries = list_folder_entries(&dir.0).expect("list entries");
        let names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();

        assert!(names.contains(&"subfolder"));
        assert!(names.contains(&"notes.md"));
        assert!(!names.contains(&"image.png"));
    }

    #[test]
    fn includes_hidden_entries() {
        let dir = TestDir::new("markive-list-hidden");
        std::fs::create_dir(dir.0.join(".obsidian")).expect("create dotdir");
        std::fs::write(dir.0.join(".hidden.md"), "# hi").expect("write hidden markdown");

        let entries = list_folder_entries(&dir.0).expect("list entries");
        let names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();

        assert!(names.contains(&".obsidian"));
        assert!(names.contains(&".hidden.md"));
    }

    #[test]
    fn sorts_folders_before_files_case_insensitively() {
        let dir = TestDir::new("markive-list-sort");
        std::fs::create_dir(dir.0.join("Zeta")).expect("create folder");
        std::fs::write(dir.0.join("apple.md"), "# a").expect("write a");
        std::fs::write(dir.0.join("Banana.md"), "# b").expect("write b");

        let entries = list_folder_entries(&dir.0).expect("list entries");
        let names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();

        assert_eq!(names, ["Zeta", "apple.md", "Banana.md"]);
    }

    #[test]
    fn flags_symlinks_and_resolves_their_canonical_target() {
        let dir = TestDir::new("markive-list-symlink");
        let target = dir.0.join("real-folder");
        std::fs::create_dir(&target).expect("create target");
        let link = dir.0.join("link-folder");
        std::os::unix::fs::symlink(&target, &link).expect("create symlink");

        let entries = list_folder_entries(&dir.0).expect("list entries");
        let linked = entries
            .iter()
            .find(|entry| entry.name == "link-folder")
            .expect("find symlinked entry");

        assert!(linked.is_symlink);
        assert!(linked.is_dir);
        assert_eq!(
            std::path::Path::new(&linked.path),
            std::fs::canonicalize(&target).expect("canonicalize target"),
        );
    }

    #[test]
    fn a_symlink_pointing_at_an_ancestor_resolves_to_that_ancestors_path() {
        // The cycle guard itself lives in the frontend (it already holds
        // the ancestor chain); this only proves the backend gives it the
        // canonical path it needs to detect one — a symlink back to `dir`
        // must resolve to `dir`'s own canonical path.
        let dir = TestDir::new("markive-list-loop");
        let link = dir.0.join("loop-to-self");
        std::os::unix::fs::symlink(&dir.0, &link).expect("create symlink");

        let entries = list_folder_entries(&dir.0).expect("list entries");
        let looped = entries
            .iter()
            .find(|entry| entry.name == "loop-to-self")
            .expect("find looping entry");

        assert_eq!(
            std::path::Path::new(&looped.path),
            std::fs::canonicalize(&dir.0).expect("canonicalize root"),
        );
    }

    #[test]
    fn missing_folder_is_reported() {
        assert!(list_folder_entries(std::path::Path::new("/nonexistent/markive-folder")).is_err());
    }
}

#[tauri::command]
fn render_markdown(markdown: &str) -> String {
    markive_core::render_markdown(markdown)
}

/// Renders Markdown source held by the frontend — pasted text, piped
/// stdin, or editor content. With a `base_dir` (the open document's
/// directory) relative image and link targets resolve; without one,
/// only absolute targets do.
#[tauri::command]
async fn render_source(
    app: tauri::AppHandle,
    markdown: String,
    base_dir: Option<String>,
) -> String {
    let rendered =
        markive_core::render_document(&markdown, base_dir.as_deref().map(std::path::Path::new));
    grant_image_access(&app, &rendered);

    rendered.html().to_owned()
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct StdinDocument {
    html: String,
    content: String,
}

/// Renders piped stdin that `main` parked in a temporary file, deleting
/// the file after reading. Rendered like clipboard text: no base
/// directory, so only absolute image paths resolve.
#[tauri::command]
async fn open_stdin_document(app: tauri::AppHandle, path: String) -> Result<StdinDocument, String> {
    let content = std::fs::read_to_string(&path)
        .map_err(|error| format!("Unable to read piped input: {error}"))?;
    let _ = std::fs::remove_file(&path);

    let rendered = markive_core::render_document(&content, None);
    grant_image_access(&app, &rendered);

    Ok(StdinDocument {
        html: rendered.html().to_owned(),
        content,
    })
}

/// Saves document content through markive-core's atomic write. The
/// save is recorded first so the file watcher ignores the resulting
/// filesystem events.
#[tauri::command]
async fn save_file(
    saves: tauri::State<'_, RecentSaves>,
    path: String,
    content: String,
) -> Result<(), String> {
    saves.record(&path);
    markive_core::save_document(std::path::Path::new(&path), &content)
        .map_err(|error| format!("Unable to save {path}: {error}"))
}

/// Timestamps of Markive's own writes, so watcher events they cause
/// are not reported back as external changes.
struct RecentSaves(Mutex<std::collections::HashMap<String, std::time::Instant>>);

/// External editors and our own atomic rename produce event bursts;
/// everything within this window of an own save is ours.
const SELF_SAVE_WINDOW: std::time::Duration = std::time::Duration::from_secs(2);

impl RecentSaves {
    fn record(&self, path: &str) {
        self.0
            .lock()
            .expect("recent saves lock poisoned")
            .insert(canonical_string(path), std::time::Instant::now());
    }

    fn is_own_save(&self, path: &str) -> bool {
        self.0
            .lock()
            .expect("recent saves lock poisoned")
            .get(&canonical_string(path))
            .is_some_and(|saved| saved.elapsed() < SELF_SAVE_WINDOW)
    }
}

/// Canonicalizes when possible so watcher event paths and save paths
/// compare equal despite symlinks like /tmp vs /private/tmp.
fn canonical_string(path: &str) -> String {
    std::fs::canonicalize(path)
        .map_or_else(|_| path.to_owned(), |p| p.to_string_lossy().into_owned())
}

/// The active document watcher; replaced when another document opens.
struct DocumentWatcher(Mutex<Option<notify::RecommendedWatcher>>);

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FileChange {
    kind: &'static str,
}

/// Watches the document at `path` for external changes, replacing any
/// previous watch. `None` stops watching (clipboard, stdin, untitled).
/// Events arrive in the frontend as `document-file-changed` with kind
/// `modified` or `removed`, decided by whether the file still exists —
/// editors that save atomically report renames, not writes.
#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
fn watch_document(
    app: tauri::AppHandle,
    watcher_state: tauri::State<'_, DocumentWatcher>,
    path: Option<String>,
) -> Result<(), String> {
    use notify::Watcher;

    let mut guard = watcher_state
        .0
        .lock()
        .expect("document watcher lock poisoned");
    *guard = None;

    let Some(path) = path else { return Ok(()) };

    let target = path.clone();
    let handle = app.clone();
    let mut watcher = notify::recommended_watcher(move |result: notify::Result<notify::Event>| {
        use tauri::{Emitter, Manager};

        let Ok(event) = result else { return };
        if !matches!(
            event.kind,
            notify::EventKind::Modify(_) | notify::EventKind::Remove(_) | notify::EventKind::Create(_)
        ) {
            return;
        }
        if handle.state::<RecentSaves>().is_own_save(&target) {
            return;
        }

        let kind = if std::path::Path::new(&target).is_file() {
            "modified"
        } else {
            "removed"
        };
        let _ = handle.emit("document-file-changed", FileChange { kind });
    })
    .map_err(|error| format!("Unable to watch {path}: {error}"))?;

    watcher
        .watch(std::path::Path::new(&path), notify::RecursiveMode::NonRecursive)
        .map_err(|error| format!("Unable to watch {path}: {error}"))?;
    *guard = Some(watcher);

    Ok(())
}

/// The directory holding lightweight session state, created on demand.
/// Lives in the per-app data directory, never beside documents.
fn session_dir(app: &tauri::AppHandle) -> Option<std::path::PathBuf> {
    use tauri::Manager;

    let dir = app.path().app_data_dir().ok()?;
    std::fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

#[derive(serde::Serialize, serde::Deserialize)]
struct WindowGeometry {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
}

/// The window geometry as of the last move or resize. Held in memory
/// because at quit the window is already gone when `ExitRequested`
/// fires, so it cannot be queried on the way out.
struct LastGeometry(Mutex<Option<WindowGeometry>>);

/// Snapshots the main window's position and size into memory. Called
/// on every move and resize.
fn record_window_geometry(app: &tauri::AppHandle) {
    use tauri::Manager;

    let Some(window) = app.get_webview_window("main") else {
        return;
    };
    let (Ok(position), Ok(size)) = (window.outer_position(), window.inner_size()) else {
        return;
    };

    *app.state::<LastGeometry>()
        .0
        .lock()
        .expect("window geometry lock poisoned") = Some(WindowGeometry {
        x: position.x,
        y: position.y,
        width: size.width,
        height: size.height,
    });
}

/// Writes the recorded window geometry to disk, called when the app
/// exits.
fn save_window_geometry(app: &tauri::AppHandle) {
    use tauri::Manager;

    let Some(dir) = session_dir(app) else { return };
    let state = app.state::<LastGeometry>();
    let guard = state.0.lock().expect("window geometry lock poisoned");
    let Some(geometry) = guard.as_ref() else {
        return;
    };

    if let Ok(json) = serde_json::to_string(geometry) {
        let _ = std::fs::write(dir.join("window.json"), json);
    }
}

/// Applies the recorded window geometry from the previous run. Called
/// right after the window is created, before content shows.
fn restore_window_geometry(app: &tauri::AppHandle, window: &tauri::WebviewWindow) {
    let Some(dir) = session_dir(app) else { return };
    let Ok(json) = std::fs::read_to_string(dir.join("window.json")) else {
        return;
    };
    let Ok(geometry) = serde_json::from_str::<WindowGeometry>(&json) else {
        return;
    };

    let _ = window.set_size(tauri::PhysicalSize::new(geometry.width, geometry.height));
    let _ = window.set_position(tauri::PhysicalPosition::new(geometry.x, geometry.y));
}

/// Returns the saved frontend session, if any. The schema is owned by
/// the frontend; the backend only stores it.
#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
fn load_session(app: tauri::AppHandle) -> Option<serde_json::Value> {
    let dir = session_dir(&app)?;
    let json = std::fs::read_to_string(dir.join("session.json")).ok()?;
    serde_json::from_str(&json).ok()
}

/// Persists the frontend session. Saved debounced on every document,
/// view, or scroll change so a quit needs no exit hook.
#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
fn save_session(app: tauri::AppHandle, session: serde_json::Value) -> Result<(), String> {
    let dir = session_dir(&app).ok_or("No application data directory")?;
    std::fs::write(dir.join("session.json"), session.to_string())
        .map_err(|error| format!("Unable to save the session: {error}"))
}

/// Handles to the menu items whose enabled/checked state follows the
/// document: Save, Save As, and Find need an open document; the View
/// check items mirror the active view mode.
struct MenuHandles {
    save: tauri::menu::MenuItem<tauri::Wry>,
    save_as: tauri::menu::MenuItem<tauri::Wry>,
    find: tauri::menu::MenuItem<tauri::Wry>,
    rendered: tauri::menu::CheckMenuItem<tauri::Wry>,
    source: tauri::menu::CheckMenuItem<tauri::Wry>,
    split: tauri::menu::CheckMenuItem<tauri::Wry>,
    theme_light: tauri::menu::CheckMenuItem<tauri::Wry>,
    theme_dark: tauri::menu::CheckMenuItem<tauri::Wry>,
    theme_system: tauri::menu::CheckMenuItem<tauri::Wry>,
}

/// Syncs menu item state with the frontend's document state. Called on
/// every document or view-mode change.
#[tauri::command]
#[allow(clippy::needless_pass_by_value)]
fn set_menu_state(
    handles: tauri::State<'_, MenuHandles>,
    has_document: bool,
    view_mode: String,
    theme: String,
) -> Result<(), String> {
    let apply = || -> tauri::Result<()> {
        handles.save.set_enabled(has_document)?;
        handles.save_as.set_enabled(has_document)?;
        handles.find.set_enabled(has_document)?;

        for (item, mode) in [
            (&handles.rendered, "rendered"),
            (&handles.source, "source"),
            (&handles.split, "split"),
        ] {
            item.set_enabled(has_document)?;
            item.set_checked(has_document && view_mode == mode)?;
        }

        for (item, preference) in [
            (&handles.theme_light, "light"),
            (&handles.theme_dark, "dark"),
            (&handles.theme_system, "system"),
        ] {
            item.set_checked(theme == preference)?;
        }
        Ok(())
    };

    apply().map_err(|error| format!("Unable to update the menu: {error}"))
}

/// Builds the application menu and returns the stateful item handles.
#[allow(clippy::too_many_lines)]
fn build_menu(app: &tauri::App) -> tauri::Result<MenuHandles> {
    use tauri::menu::{CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};

    let new_item = MenuItemBuilder::with_id("new", "New")
        .accelerator("CmdOrCtrl+N")
        .build(app)?;
    let open = MenuItemBuilder::with_id("open", "Open…")
        .accelerator("CmdOrCtrl+O")
        .build(app)?;
    let open_folder = MenuItemBuilder::with_id("open-folder", "Open Folder…")
        .accelerator("Shift+CmdOrCtrl+O")
        .build(app)?;
    let save = MenuItemBuilder::with_id("save", "Save")
        .accelerator("CmdOrCtrl+S")
        .enabled(false)
        .build(app)?;
    let save_as = MenuItemBuilder::with_id("save-as", "Save As…")
        .accelerator("Shift+CmdOrCtrl+S")
        .enabled(false)
        .build(app)?;
    let find = MenuItemBuilder::with_id("find", "Find…")
        .accelerator("CmdOrCtrl+F")
        .enabled(false)
        .build(app)?;
    let rendered = CheckMenuItemBuilder::with_id("view-rendered", "Rendered")
        .accelerator("CmdOrCtrl+1")
        .enabled(false)
        .build(app)?;
    let source = CheckMenuItemBuilder::with_id("view-source", "Source")
        .accelerator("CmdOrCtrl+2")
        .enabled(false)
        .build(app)?;
    let split = CheckMenuItemBuilder::with_id("view-split", "Split")
        .accelerator("CmdOrCtrl+3")
        .enabled(false)
        .build(app)?;

    let settings = MenuItemBuilder::with_id("settings", "Settings…")
        .accelerator("CmdOrCtrl+,")
        .build(app)?;

    let app_menu = SubmenuBuilder::new(app, "Markive")
        .about(None)
        .separator()
        .item(&settings)
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .quit()
        .build()?;
    let file_menu = SubmenuBuilder::new(app, "File")
        .item(&new_item)
        .item(&open)
        .item(&open_folder)
        .separator()
        .item(&save)
        .item(&save_as)
        .separator()
        .close_window()
        .build()?;
    // Undo and Redo are custom items: the predefined ones fire
    // WebKit's undo: selector, which never reaches CodeMirror's own
    // history (#76). These forward to the frontend like every other
    // custom item.
    let undo = MenuItemBuilder::with_id("undo", "Undo")
        .accelerator("CmdOrCtrl+Z")
        .build(app)?;
    let redo = MenuItemBuilder::with_id("redo", "Redo")
        .accelerator("Shift+CmdOrCtrl+Z")
        .build(app)?;

    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .item(&undo)
        .item(&redo)
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .separator()
        .item(&find)
        .build()?;
    let theme_light = CheckMenuItemBuilder::with_id("theme-light", "Light").build(app)?;
    let theme_dark = CheckMenuItemBuilder::with_id("theme-dark", "Dark").build(app)?;
    let theme_system = CheckMenuItemBuilder::with_id("theme-system", "System")
        .checked(true)
        .build(app)?;
    let appearance_menu = SubmenuBuilder::new(app, "Appearance")
        .item(&theme_light)
        .item(&theme_dark)
        .item(&theme_system)
        .build()?;

    let view_menu = SubmenuBuilder::new(app, "View")
        .item(&rendered)
        .item(&source)
        .item(&split)
        .separator()
        .item(&appearance_menu)
        .separator()
        .fullscreen()
        .build()?;
    let window_menu = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .build()?;

    let menu = MenuBuilder::new(app)
        .items(&[&app_menu, &file_menu, &edit_menu, &view_menu, &window_menu])
        .build()?;
    app.set_menu(menu)?;

    Ok(MenuHandles {
        save,
        save_as,
        find,
        rendered,
        source,
        split,
        theme_light,
        theme_dark,
        theme_system,
    })
}

/// Symlinks the running binary to /usr/local/bin/markive so the CLI
/// (#49) works from a terminal after installing the app. Tries a
/// direct symlink first; when /usr/local/bin is not writable, asks for
/// administrator privileges through the system prompt.
#[tauri::command]
fn install_cli() -> Result<String, String> {
    let exe = std::env::current_exe()
        .map_err(|error| format!("Unable to locate the running binary: {error}"))?;
    let target = std::path::Path::new("/usr/local/bin/markive");

    let direct = || -> std::io::Result<()> {
        std::fs::create_dir_all("/usr/local/bin")?;
        if target.symlink_metadata().is_ok() {
            std::fs::remove_file(target)?;
        }
        std::os::unix::fs::symlink(&exe, target)
    };

    if direct().is_ok() {
        return Ok(format!("Linked {} to {}", target.display(), exe.display()));
    }

    // Paths come from the OS, but single quotes still end the shell
    // string; refuse rather than build a broken command.
    let exe_str = exe.to_string_lossy();
    if exe_str.contains('\'') {
        return Err("The application path contains an unsupported quote character.".into());
    }

    let script = format!(
        "do shell script \"mkdir -p /usr/local/bin && ln -sf '{exe_str}' '/usr/local/bin/markive'\" with administrator privileges"
    );
    let output = std::process::Command::new("osascript")
        .args(["-e", &script])
        .output()
        .map_err(|error| format!("Unable to run the install step: {error}"))?;

    if output.status.success() {
        Ok(format!("Linked {} to {}", target.display(), exe.display()))
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("User canceled") {
            Err("Installation canceled.".into())
        } else {
            Err(format!("Unable to install the command line tool: {}", stderr.trim()))
        }
    }
}

fn read_clipboard_files() -> Result<Vec<String>, String> {
    use clipboard_rs::{Clipboard, ClipboardContext};

    let clipboard = ClipboardContext::new()
        .map_err(|error| format!("Unable to access the clipboard: {error}"))?;

    Ok(clipboard.get_files().unwrap_or_default())
}

/// Returns the absolute paths of files currently on the clipboard.
///
/// Returns an empty list when the clipboard holds no file references,
/// so plain-text paste can fall back to reading the clipboard as text.
#[tauri::command]
fn clipboard_files() -> Result<Vec<String>, String> {
    let files = read_clipboard_files();

    #[cfg(debug_assertions)]
    eprintln!("clipboard_files: {files:?}");

    files
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    use std::process::Command;

    /// Overwrites the user clipboard, so it only runs with `--ignored`.
    #[test]
    #[ignore = "overwrites the clipboard"]
    fn reads_copied_file_from_clipboard() {
        let path = std::env::temp_dir().join(format!("markive-clipboard-{}.md", std::process::id()));
        std::fs::write(&path, "# Copied\n").expect("write test document");

        let script = format!(
            "set the clipboard to (POSIX file \"{}\")",
            path.display()
        );
        let status = Command::new("osascript")
            .args(["-e", &script])
            .status()
            .expect("run osascript");
        assert!(status.success(), "osascript failed to set the clipboard");

        let files = clipboard_files().expect("read clipboard files");

        assert_eq!(files.len(), 1);
        assert_eq!(
            std::fs::canonicalize(&files[0]).expect("canonicalize clipboard path"),
            std::fs::canonicalize(&path).expect("canonicalize test path"),
        );

        std::fs::remove_file(&path).expect("remove test document");
    }

    #[test]
    fn file_url_converts_to_a_document_open_request() {
        let path = std::env::temp_dir().join(format!("markive-open-{}.md", std::process::id()));
        std::fs::write(&path, "# Opened\n").expect("write test document");

        let url = tauri::Url::from_file_path(&path).expect("build file URL");
        let request = open_request_from_url(&url);

        assert_eq!(
            std::fs::canonicalize(request.path.expect("document path")).expect("canonicalize"),
            std::fs::canonicalize(&path).expect("canonicalize test path"),
        );
        assert!(request.folder_path.is_none());
        assert!(request.error.is_none());

        std::fs::remove_file(&path).expect("remove test document");
    }

    #[test]
    fn folder_url_converts_to_a_folder_open_request() {
        let dir = std::env::temp_dir().join(format!("markive-open-folder-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("create test folder");

        let url = tauri::Url::from_file_path(&dir).expect("build file URL");
        let request = open_request_from_url(&url);

        assert_eq!(
            std::fs::canonicalize(request.folder_path.expect("folder path")).expect("canonicalize"),
            std::fs::canonicalize(&dir).expect("canonicalize test path"),
        );
        assert!(request.path.is_none());
        assert!(request.error.is_none());

        std::fs::remove_dir_all(&dir).expect("remove test folder");
    }

    #[test]
    fn non_markdown_file_url_is_rejected() {
        let path = std::env::temp_dir().join(format!("markive-open-{}.txt", std::process::id()));
        std::fs::write(&path, "plain text\n").expect("write test document");

        let url = tauri::Url::from_file_path(&path).expect("build file URL");
        let error = open_request_from_url(&url).error.expect("reject non-Markdown file");
        assert!(error.contains("not a Markdown file"), "unexpected error: {error}");

        std::fs::remove_file(&path).expect("remove test document");
    }

    #[test]
    fn missing_file_url_is_rejected() {
        let url = tauri::Url::from_file_path("/nonexistent/markive-missing.md")
            .expect("build file URL");
        assert!(open_request_from_url(&url).error.is_some());
    }

    #[test]
    fn non_file_url_is_rejected() {
        let url: tauri::Url = "https://example.com/notes.md".parse().expect("parse URL");
        let error = open_request_from_url(&url).error.expect("reject non-file URL");
        assert!(error.contains("not a file path"), "unexpected error: {error}");
    }
}

/// Creates the main window and menu.
///
/// The window is created here instead of by the config (`create:
/// false`) to attach the navigation policy: the webview may only load
/// the app itself. External links open in the default browser; a click
/// that slips past the frontend interception must not replace the app.
fn setup_app(app: &tauri::App) -> tauri::Result<()> {
    use tauri::Manager;

    let config = app
        .config()
        .app
        .windows
        .first()
        .expect("main window config missing")
        .clone();
    let window = tauri::WebviewWindowBuilder::from_config(app, &config)?
        .on_navigation(|url| match url.scheme() {
            "tauri" => true,
            "http" | "https" if cfg!(debug_assertions) => {
                url.host_str() == Some("localhost") || url.host_str() == Some("127.0.0.1")
            }
            _ => false,
        })
        .build()?;
    restore_window_geometry(app.handle(), &window);
    // An untouched window never fires a move or resize, so the initial
    // geometry is recorded here.
    record_window_geometry(app.handle());

    let handles = build_menu(app)?;
    app.manage(handles);
    Ok(())
}

/// Starts the Markive desktop application, opening `launch_path` when
/// one was given on the command line.
///
/// # Panics
///
/// Panics when the Tauri runtime cannot initialize or exits with an error.
pub fn run(launch: Launch) {
    let app = tauri::Builder::default()
        // Registered first so a second instance forwards its arguments
        // and exits before any other initialization runs.
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            use tauri::Manager;

            if let Some(request) = OpenRequest::from_forwarded_args(&argv[1..]) {
                deliver_open_request(app, request);
            }
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            setup_app(app)?;
            Ok(())
        })
        // Custom menu items forward to the frontend, which owns the
        // document state and the actions.
        .on_menu_event(|app, event| {
            use tauri::Emitter;

            let id = event.id().as_ref();
            if matches!(
                id,
                "new" | "open"
                    | "open-folder"
                    | "undo"
                    | "redo"
                    | "save"
                    | "save-as"
                    | "find"
                    | "view-rendered"
                    | "view-source"
                    | "view-split"
                    | "theme-light"
                    | "theme-dark"
                    | "theme-system"
                    | "settings"
            ) {
                let _ = app.emit("menu-action", id);
            }
        })
        .manage(Mutex::new(LaunchState {
            pending: OpenRequest::from_launch(launch),
            frontend_ready: false,
        }))
        .manage(RecentSaves(Mutex::new(std::collections::HashMap::new())))
        .manage(DocumentWatcher(Mutex::new(None)))
        .manage(LastGeometry(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            open_document,
            open_folder,
            read_folder_entries,
            open_stdin_document,
            render_markdown,
            render_source,
            clipboard_files,
            launch_document,
            save_file,
            watch_document,
            set_menu_state,
            load_session,
            save_session,
            install_cli
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Markive");

    app.run(|app, event| {
        // Geometry is snapshotted on every move and resize and written
        // on the way out — at exit the window itself is already gone.
        match &event {
            tauri::RunEvent::WindowEvent {
                event: tauri::WindowEvent::Moved(_) | tauri::WindowEvent::Resized(_),
                ..
            } => record_window_geometry(app),
            tauri::RunEvent::ExitRequested { .. } | tauri::RunEvent::Exit => save_window_geometry(app),
            _ => {}
        }

        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Opened { urls } = &event {
            for url in urls {
                deliver_open_request(app, open_request_from_url(url));
            }
        }

        #[cfg(not(target_os = "macos"))]
        let _ = (app, event);
    });
}
