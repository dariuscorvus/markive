#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use ammonia::Builder;
use pulldown_cmark::{Options, Parser};

/// File extensions Markive treats as Markdown documents.
pub const MARKDOWN_EXTENSIONS: [&str; 4] = ["md", "markdown", "mdown", "mkd"];

/// Returns true when the path has a Markdown file extension.
#[must_use]
pub fn is_markdown_path(path: &Path) -> bool {
    path.extension()
        .and_then(OsStr::to_str)
        .is_some_and(|extension| {
            MARKDOWN_EXTENSIONS
                .iter()
                .any(|known| extension.eq_ignore_ascii_case(known))
        })
}

#[derive(Debug, Eq, PartialEq)]
pub struct Document {
    path: PathBuf,
    content: String,
}

impl Document {
    #[must_use]
    pub fn path(&self) -> &Path {
        &self.path
    }

    #[must_use]
    pub fn content(&self) -> &str {
        &self.content
    }
}

/// Reads a UTF-8 document without modifying it.
///
/// # Errors
///
/// Returns an error when the file cannot be read or is not valid UTF-8.
pub fn open_document(path: impl AsRef<Path>) -> io::Result<Document> {
    let path = path.as_ref();
    let content = fs::read_to_string(path)?;

    Ok(Document {
        path: path.to_path_buf(),
        content,
    })
}

#[must_use]
pub fn render_markdown(markdown: &str) -> String {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_TASKLISTS);

    let parser = Parser::new_ext(markdown, options);
    let mut html = String::new();
    pulldown_cmark::html::push_html(&mut html, parser);

    Builder::default()
        .add_tags(["input"])
        .add_tag_attributes("input", ["checked", "disabled", "type"])
        .clean(&html)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process;

    #[test]
    fn opens_utf8_document_without_changing_content() {
        let path = std::env::temp_dir().join(format!("markive-{}.md", process::id()));
        let content = "# Markive\n\nFiles first.\n";

        fs::write(&path, content).expect("write test document");

        let document = open_document(&path).expect("open test document");

        assert_eq!(document.path(), path.as_path());
        assert_eq!(document.content(), content);

        fs::remove_file(path).expect("remove test document");
    }

    #[test]
    fn recognizes_markdown_extensions_case_insensitively() {
        assert!(is_markdown_path(Path::new("/notes/todo.md")));
        assert!(is_markdown_path(Path::new("README.MD")));
        assert!(is_markdown_path(Path::new("doc.Markdown")));
        assert!(!is_markdown_path(Path::new("archive.md.zip")));
        assert!(!is_markdown_path(Path::new("plain.txt")));
        assert!(!is_markdown_path(Path::new("no-extension")));
    }

    #[test]
    fn renders_github_flavored_markdown() {
        let markdown =
            "# Markive\n\n~~old~~\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\n- [x] rendered\n";

        let html = render_markdown(markdown);

        assert!(html.contains("<h1>Markive</h1>"));
        assert!(html.contains("<del>old</del>"));
        assert!(html.contains("<table>"));
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("checked"));
    }

    #[test]
    fn removes_unsafe_html() {
        let markdown = "<script>alert('no')</script>\n\n<img src=x onerror=alert('no')>\n\n[bad](javascript:alert('no'))";

        let html = render_markdown(markdown);

        assert!(!html.contains("<script"));
        assert!(!html.contains("<img"));
        assert!(!html.contains("javascript:"));
        assert!(html.contains("&lt;img"));
    }
}
