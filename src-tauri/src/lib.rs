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
            // The main window is created here instead of by the config
            // (`create: false`) to attach the navigation policy: the
            // webview may only load the app itself. External links open
            // in the default browser; a click that slips past the
            // frontend interception must not replace the app.
            let config = app
                .config()
                .app
                .windows
                .first()
                .expect("main window config missing")
                .clone();
            tauri::WebviewWindowBuilder::from_config(app, &config)?
                .on_navigation(|url| match url.scheme() {
                    "tauri" => true,
                    "http" | "https" if cfg!(debug_assertions) => {
                        url.host_str() == Some("localhost") || url.host_str() == Some("127.0.0.1")
                    }
                    _ => false,
                })
                .build()?;
            Ok(())
        })
        .manage(Mutex::new(LaunchState {
            pending: OpenRequest::from_launch(launch),
            frontend_ready: false,
        }))
        .manage(RecentSaves(Mutex::new(std::collections::HashMap::new())))
        .manage(DocumentWatcher(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            open_document,
            open_stdin_document,
            render_markdown,
            render_source,
            clipboard_files,
            launch_document,
            save_file,
            watch_document
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Markive");

    app.run(|app, event| {
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
