#![forbid(unsafe_code)]

pub mod cli;

use std::sync::Mutex;

/// What the process was asked to show at startup.
pub enum Launch {
    /// An empty window.
    Window,
    /// A validated, absolute document path.
    Document(String),
    /// A temporary file holding piped stdin, deleted after reading.
    StdinFile(String),
}

/// A document open request delivered to the frontend: at startup through
/// the `launch_document` command, afterwards as an `open-document` event.
#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenRequest {
    path: Option<String>,
    stdin_path: Option<String>,
    error: Option<String>,
}

impl OpenRequest {
    fn from_launch(launch: Launch) -> Option<Self> {
        match launch {
            Launch::Window => None,
            Launch::Document(path) => Some(Self {
                path: Some(path),
                stdin_path: None,
                error: None,
            }),
            Launch::StdinFile(file) => Some(Self {
                path: None,
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
                stdin_path: Some(file.clone()),
                error: None,
            }),
            [path] => Some(match cli::validate_document_path(path) {
                Ok(()) => Self {
                    path: Some(path.clone()),
                    stdin_path: None,
                    error: None,
                },
                Err(error) => Self {
                    path: None,
                    stdin_path: None,
                    error: Some(error),
                },
            }),
            _ => None,
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

/// Converts a URL from a macOS open-file event into a validated
/// Markdown document path.
#[cfg(target_os = "macos")]
fn document_path_from_url(url: &tauri::Url) -> Result<String, String> {
    let path = url
        .to_file_path()
        .map_err(|()| format!("{url} is not a file path"))?;
    let path = path.to_string_lossy().into_owned();
    cli::validate_document_path(&path)?;
    Ok(path)
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
fn build_menu(app: &tauri::App) -> tauri::Result<MenuHandles> {
    use tauri::menu::{CheckMenuItemBuilder, MenuBuilder, MenuItemBuilder, SubmenuBuilder};

    let new_item = MenuItemBuilder::with_id("new", "New")
        .accelerator("CmdOrCtrl+N")
        .build(app)?;
    let open = MenuItemBuilder::with_id("open", "Open…")
        .accelerator("CmdOrCtrl+O")
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

    let app_menu = SubmenuBuilder::new(app, "Markive")
        .about(None)
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
        .separator()
        .item(&save)
        .item(&save_as)
        .separator()
        .close_window()
        .build()?;
    let edit_menu = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
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
    fn file_url_to_markdown_path() {
        let path = std::env::temp_dir().join(format!("markive-open-{}.md", std::process::id()));
        std::fs::write(&path, "# Opened\n").expect("write test document");

        let url = tauri::Url::from_file_path(&path).expect("build file URL");
        let converted = document_path_from_url(&url).expect("convert URL");
        assert_eq!(
            std::fs::canonicalize(&converted).expect("canonicalize converted path"),
            std::fs::canonicalize(&path).expect("canonicalize test path"),
        );

        std::fs::remove_file(&path).expect("remove test document");
    }

    #[test]
    fn non_markdown_file_url_is_rejected() {
        let path = std::env::temp_dir().join(format!("markive-open-{}.txt", std::process::id()));
        std::fs::write(&path, "plain text\n").expect("write test document");

        let url = tauri::Url::from_file_path(&path).expect("build file URL");
        let error = document_path_from_url(&url).expect_err("reject non-Markdown file");
        assert!(error.contains("not a Markdown file"), "unexpected error: {error}");

        std::fs::remove_file(&path).expect("remove test document");
    }

    #[test]
    fn missing_file_url_is_rejected() {
        let url = tauri::Url::from_file_path("/nonexistent/markive-missing.md")
            .expect("build file URL");
        assert!(document_path_from_url(&url).is_err());
    }

    #[test]
    fn non_file_url_is_rejected() {
        let url: tauri::Url = "https://example.com/notes.md".parse().expect("parse URL");
        let error = document_path_from_url(&url).expect_err("reject non-file URL");
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
                    | "save"
                    | "save-as"
                    | "find"
                    | "view-rendered"
                    | "view-source"
                    | "view-split"
                    | "theme-light"
                    | "theme-dark"
                    | "theme-system"
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
            open_stdin_document,
            render_markdown,
            render_source,
            clipboard_files,
            launch_document,
            save_file,
            watch_document,
            set_menu_state,
            load_session,
            save_session
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
                let request = match document_path_from_url(url) {
                    Ok(path) => OpenRequest {
                        path: Some(path),
                        stdin_path: None,
                        error: None,
                    },
                    Err(error) => OpenRequest {
                        path: None,
                        stdin_path: None,
                        error: Some(error),
                    },
                };
                deliver_open_request(app, request);
            }
        }

        #[cfg(not(target_os = "macos"))]
        let _ = (app, event);
    });
}
