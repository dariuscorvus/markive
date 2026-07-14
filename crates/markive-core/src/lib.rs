#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use std::path::Component;

use ammonia::Builder;
use percent_encoding::percent_decode_str;
use pulldown_cmark::{Event, Options, Parser, Tag};

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

/// A document rendered against a filesystem base directory.
#[derive(Debug, Eq, PartialEq)]
pub struct RenderedDocument {
    html: String,
    local_images: Vec<PathBuf>,
}

impl RenderedDocument {
    #[must_use]
    pub fn html(&self) -> &str {
        &self.html
    }

    /// Absolute paths of every local image the document references.
    #[must_use]
    pub fn local_images(&self) -> &[PathBuf] {
        &self.local_images
    }
}

fn markdown_options() -> Options {
    let mut options = Options::empty();
    options.insert(Options::ENABLE_STRIKETHROUGH);
    options.insert(Options::ENABLE_TABLES);
    options.insert(Options::ENABLE_TASKLISTS);
    options
}

fn sanitize(html: &str) -> String {
    Builder::default()
        .add_tags(["input"])
        .add_tag_attributes("input", ["checked", "disabled", "type"])
        .clean(html)
        .to_string()
}

#[must_use]
pub fn render_markdown(markdown: &str) -> String {
    let parser = Parser::new_ext(markdown, markdown_options());
    let mut html = String::new();
    pulldown_cmark::html::push_html(&mut html, parser);

    sanitize(&html)
}

/// Renders Markdown with local image sources resolved to absolute
/// paths under `base_dir` (the directory of the document).
///
/// Remote (`http:`, `https:`, protocol-relative) sources are left
/// untouched. Relative sources are joined to `base_dir` and normalized
/// lexically; absolute sources are normalized in place. Every resolved
/// path is reported in [`RenderedDocument::local_images`] so callers
/// can grant access to exactly those files.
///
/// Without a `base_dir` — a document that never came from a file, like
/// pasted clipboard text — only absolute sources resolve; relative
/// sources have nothing to resolve against and pass through untouched.
#[must_use]
pub fn render_document(markdown: &str, base_dir: Option<&Path>) -> RenderedDocument {
    let mut local_images = Vec::new();

    let events = Parser::new_ext(markdown, markdown_options()).map(|event| match event {
        Event::Start(Tag::Image {
            link_type,
            dest_url,
            title,
            id,
        }) => {
            let dest_url = match resolve_local_image(&dest_url, base_dir) {
                Some(path) => {
                    let resolved = path.to_string_lossy().into_owned();
                    local_images.push(path);
                    resolved.into()
                }
                None => dest_url,
            };
            Event::Start(Tag::Image {
                link_type,
                dest_url,
                title,
                id,
            })
        }
        other => other,
    });

    let mut html = String::new();
    pulldown_cmark::html::push_html(&mut html, events);

    RenderedDocument {
        html: sanitize(&html),
        local_images,
    }
}

/// True when `src` names a remote or otherwise non-filesystem target:
/// a URL scheme (RFC 3986 `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`)
/// or a protocol-relative `//` prefix.
fn has_url_scheme(src: &str) -> bool {
    if src.starts_with("//") {
        return true;
    }

    src.split_once(':').is_some_and(|(scheme, _)| {
        let mut chars = scheme.chars();
        chars
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic())
            && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    })
}

/// Resolves an image source to an absolute filesystem path, or `None`
/// when the source is remote, empty, not decodable, or relative with
/// no base directory to resolve against.
fn resolve_local_image(src: &str, base_dir: Option<&Path>) -> Option<PathBuf> {
    if src.is_empty() || has_url_scheme(src) {
        return None;
    }

    // Markdown sources are URLs, so `my image.png` arrives as
    // `my%20image.png`; the filesystem needs the decoded form.
    let decoded = percent_decode_str(src).decode_utf8().ok()?;
    let path = Path::new(decoded.as_ref());
    let joined = if path.is_absolute() {
        path.to_path_buf()
    } else {
        base_dir?.join(path)
    };

    Some(normalize_lexically(&joined))
}

/// Removes `.` and `..` components without touching the filesystem,
/// clamping traversal at the root.
fn normalize_lexically(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();

    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }

    normalized
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
    fn resolves_relative_images_against_the_base_directory() {
        let rendered = render_document("![logo](images/logo.png)", Some(Path::new("/docs/notes")));

        assert!(rendered.html().contains("src=\"/docs/notes/images/logo.png\""));
        assert_eq!(
            rendered.local_images(),
            [PathBuf::from("/docs/notes/images/logo.png")]
        );
    }

    #[test]
    fn resolves_parent_traversal_lexically() {
        let rendered = render_document("![up](../shared/./a.png)", Some(Path::new("/docs/notes")));

        assert!(rendered.html().contains("src=\"/docs/shared/a.png\""));
        assert_eq!(rendered.local_images(), [PathBuf::from("/docs/shared/a.png")]);
    }

    #[test]
    fn clamps_traversal_at_the_root() {
        let rendered = render_document("![x](../../../../etc/a.png)", Some(Path::new("/docs")));

        assert_eq!(rendered.local_images(), [PathBuf::from("/etc/a.png")]);
    }

    #[test]
    fn keeps_absolute_image_paths_and_reports_them() {
        let rendered = render_document("![abs](/pictures/cat.png)", Some(Path::new("/docs")));

        assert!(rendered.html().contains("src=\"/pictures/cat.png\""));
        assert_eq!(rendered.local_images(), [PathBuf::from("/pictures/cat.png")]);
    }

    #[test]
    fn leaves_remote_images_untouched() {
        let markdown = "![a](https://example.com/a.png)\n\n![b](//example.com/b.png)";

        let rendered = render_document(markdown, Some(Path::new("/docs")));

        assert!(rendered.html().contains("src=\"https://example.com/a.png\""));
        assert!(rendered.local_images().is_empty());
    }

    #[test]
    fn resolves_absolute_images_without_a_base_directory() {
        let rendered = render_document("![abs](/pictures/cat.png)", None);

        assert!(rendered.html().contains("src=\"/pictures/cat.png\""));
        assert_eq!(rendered.local_images(), [PathBuf::from("/pictures/cat.png")]);
    }

    #[test]
    fn leaves_relative_images_untouched_without_a_base_directory() {
        let rendered = render_document("![rel](images/logo.png)", None);

        assert!(rendered.html().contains("src=\"images/logo.png\""));
        assert!(rendered.local_images().is_empty());
    }

    #[test]
    fn decodes_percent_encoded_image_paths() {
        let rendered = render_document("![shot](my%20shot.png)", Some(Path::new("/docs")));

        assert_eq!(rendered.local_images(), [PathBuf::from("/docs/my shot.png")]);
    }

    #[test]
    fn render_markdown_keeps_relative_image_sources() {
        let html = render_markdown("![logo](images/logo.png)");

        assert!(html.contains("src=\"images/logo.png\""));
    }

    #[test]
    fn render_document_still_removes_unsafe_html() {
        let markdown = "<script>alert('no')</script>\n\n[bad](javascript:alert('no'))";

        let rendered = render_document(markdown, Some(Path::new("/docs")));

        assert!(!rendered.html().contains("<script"));
        assert!(!rendered.html().contains("javascript:"));
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
