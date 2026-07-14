#![forbid(unsafe_code)]

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenedDocument {
    path: String,
    content: String,
}

#[tauri::command]
async fn open_document(path: String) -> Result<OpenedDocument, String> {
    let document = markive_core::open_document(&path)
        .map_err(|error| format!("Unable to read {path}: {error}"))?;

    Ok(OpenedDocument {
        path: document.path().to_string_lossy().into_owned(),
        content: document.content().to_owned(),
    })
}

#[tauri::command]
fn render_markdown(markdown: &str) -> String {
    markive_core::render_markdown(markdown)
}

/// Starts the Markive desktop application.
///
/// # Panics
///
/// Panics when the Tauri runtime cannot initialize or exits with an error.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![open_document, render_markdown])
        .run(tauri::generate_context!())
        .expect("failed to run Markive");
}
