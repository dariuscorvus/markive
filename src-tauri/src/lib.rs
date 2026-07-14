#![forbid(unsafe_code)]

pub mod cli;

use std::sync::Mutex;

/// A document open request delivered to the frontend: at startup through
/// the `launch_document` command, afterwards as an `open-document` event.
#[derive(Clone, serde::Serialize)]
struct OpenRequest {
    path: Option<String>,
    error: Option<String>,
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
#[cfg(target_os = "macos")]
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
    })
}

#[tauri::command]
fn render_markdown(markdown: &str) -> String {
    markive_core::render_markdown(markdown)
}

/// Renders pasted Markdown that has no backing file: absolute image
/// paths resolve, relative ones have no base directory and stay as
/// written.
#[tauri::command]
async fn render_clipboard(app: tauri::AppHandle, markdown: String) -> String {
    let rendered = markive_core::render_document(&markdown, None);
    grant_image_access(&app, &rendered);

    rendered.html().to_owned()
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
pub fn run(launch_path: Option<String>) {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(Mutex::new(LaunchState {
            pending: launch_path.map(|path| OpenRequest {
                path: Some(path),
                error: None,
            }),
            frontend_ready: false,
        }))
        .invoke_handler(tauri::generate_handler![
            open_document,
            render_markdown,
            render_clipboard,
            clipboard_files,
            launch_document
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Markive");

    app.run(|app, event| {
        #[cfg(target_os = "macos")]
        if let tauri::RunEvent::Opened { urls } = event {
            for url in &urls {
                let request = match document_path_from_url(url) {
                    Ok(path) => OpenRequest {
                        path: Some(path),
                        error: None,
                    },
                    Err(error) => OpenRequest {
                        path: None,
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
