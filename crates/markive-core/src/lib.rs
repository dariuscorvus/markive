#![forbid(unsafe_code)]

use std::ffi::OsStr;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use std::path::Component;

use ammonia::Builder;
use percent_encoding::percent_decode_str;
use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

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

/// Saves `content` to `path` without risking the original: the content
/// goes to a temporary file in the same directory, is flushed to disk,
/// and atomically renamed over the original. A failure at any step
/// leaves the original file unchanged.
///
/// # Errors
///
/// Returns an error when the target is read-only, the directory is not
/// writable, or any write, flush, or rename fails.
pub fn save_document(path: &Path, content: &str) -> io::Result<()> {
    let original = fs::metadata(path);

    // rename() replaces a read-only file when the directory is
    // writable; refusing here keeps the read-only bit meaningful.
    if let Ok(metadata) = &original
        && metadata.permissions().readonly()
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is read-only", path.display()),
        ));
    }

    let directory = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no directory"))?;
    let file_name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    let temp = directory.join(format!(
        ".{}.markive-{}.tmp",
        file_name.to_string_lossy(),
        std::process::id()
    ));

    let result = (|| {
        let mut file = fs::File::create(&temp)?;
        io::Write::write_all(&mut file, content.as_bytes())?;
        file.sync_all()?;
        // The rename keeps the temp file's permissions, not the
        // original's; carry them over.
        if let Ok(metadata) = &original {
            fs::set_permissions(&temp, metadata.permissions())?;
        }
        fs::rename(&temp, path)
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }

    result
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
    let mut builder = Builder::default();
    // Allow common structural HTML elements and attributes for markdown documents.
    builder
        .add_tags([
            "div", "section", "article", "aside", "main", "figure", "figcaption",
            "details", "summary", "dialog", "data", "mark", "meter", "progress", "time",
            "input", "button",
        ])
        .add_tag_attributes("div", ["class", "id"])
        .add_tag_attributes("section", ["class", "id"])
        .add_tag_attributes("article", ["class", "id"])
        .add_tag_attributes("figure", ["class", "id"])
        .add_tag_attributes("details", ["open"])
        .add_tag_attributes("input", ["checked", "disabled", "type"])
        .add_tag_attributes("button", ["disabled", "type"])
        .add_tag_attributes("data", ["value"])
        .add_tag_attributes("meter", ["value", "min", "max", "low", "high"])
        .add_tag_attributes("progress", ["value", "max"])
        .add_tag_attributes("time", ["datetime"]);
    for heading in ["h1", "h2", "h3", "h4", "h5", "h6"] {
        builder.add_tag_attributes(heading, ["id"]);
    }
    builder.clean(html).to_string()
}

/// GitHub-style anchor slug: lowercase, alphanumerics kept, spaces and
/// hyphens become hyphens, everything else dropped.
fn slugify(text: &str) -> String {
    text.chars()
        .filter_map(|c| {
            if c.is_alphanumeric() {
                Some(c.to_lowercase().next().unwrap_or(c))
            } else if c == ' ' || c == '-' {
                Some('-')
            } else {
                None
            }
        })
        .collect()
}

/// Parses Markdown and gives every heading without an explicit id a
/// slug generated from its text, deduplicated with `-N` suffixes.
fn events_with_heading_ids(markdown: &str) -> Vec<Event<'_>> {
    let mut events: Vec<Event> = Parser::new_ext(markdown, markdown_options()).collect();
    let mut seen = std::collections::HashMap::<String, usize>::new();

    for index in 0..events.len() {
        let Event::Start(Tag::Heading { id: None, .. }) = &events[index] else {
            continue;
        };

        let mut text = String::new();
        for event in &events[index + 1..] {
            match event {
                Event::End(TagEnd::Heading(_)) => break,
                Event::Text(t) | Event::Code(t) => text.push_str(t),
                _ => {}
            }
        }

        let slug = slugify(&text);
        let count = seen.entry(slug.clone()).or_insert(0);
        let unique = if *count == 0 {
            slug
        } else {
            format!("{slug}-{count}")
        };
        *count += 1;

        if let Event::Start(Tag::Heading { id, .. }) = &mut events[index] {
            *id = Some(unique.into());
        }
    }

    events
}

#[must_use]
pub fn render_markdown(markdown: &str) -> String {
    let mut html = String::new();
    pulldown_cmark::html::push_html(&mut html, events_with_heading_ids(markdown).into_iter());

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

    let events = events_with_heading_ids(markdown)
        .into_iter()
        .map(|event| match event {
            Event::Start(Tag::Image {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                let dest_url = match resolve_local_target(&dest_url, base_dir) {
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
            // Local link targets become absolute so the app can open
            // them regardless of its working directory. Anchors and
            // URLs pass through.
            Event::Start(Tag::Link {
                link_type,
                dest_url,
                title,
                id,
            }) => {
                let dest_url = if dest_url.starts_with('#') {
                    dest_url
                } else {
                    match resolve_local_target(&dest_url, base_dir) {
                        Some(path) => path.to_string_lossy().into_owned().into(),
                        None => dest_url,
                    }
                };
                Event::Start(Tag::Link {
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
fn resolve_local_target(src: &str, base_dir: Option<&Path>) -> Option<PathBuf> {
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

        assert!(html.contains("<h1 id=\"markive\">Markive</h1>"));
        assert!(html.contains("<del>old</del>"));
        assert!(html.contains("<table>"));
        assert!(html.contains("type=\"checkbox\""));
        assert!(html.contains("checked"));
    }

    #[test]
    fn save_round_trips_bytes_exactly() {
        let path = std::env::temp_dir().join(format!("markive-save-{}.md", process::id()));
        let content = "# Ünïcode 🎉\r\nCRLF line\r\n\nLF line\n";

        save_document(&path, content).expect("save document");

        assert_eq!(fs::read(&path).expect("read saved file"), content.as_bytes());
        fs::remove_file(&path).expect("remove test file");
    }

    #[test]
    fn save_replaces_existing_content() {
        let path = std::env::temp_dir().join(format!("markive-save-replace-{}.md", process::id()));
        fs::write(&path, "old").expect("write original");

        save_document(&path, "new").expect("save document");

        assert_eq!(fs::read_to_string(&path).expect("read"), "new");
        fs::remove_file(&path).expect("remove test file");
    }

    #[test]
    fn save_refuses_read_only_files_and_keeps_them_unchanged() {
        let path = std::env::temp_dir().join(format!("markive-save-ro-{}.md", process::id()));
        fs::write(&path, "protected").expect("write original");
        let mut permissions = fs::metadata(&path).expect("metadata").permissions();
        permissions.set_readonly(true);
        fs::set_permissions(&path, permissions.clone()).expect("set read-only");

        let error = save_document(&path, "overwrite").expect_err("refuse read-only file");

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read_to_string(&path).expect("read"), "protected");

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
                .expect("restore permissions");
        }
        fs::remove_file(&path).expect("remove test file");
    }

    #[test]
    fn save_into_a_missing_directory_fails_cleanly() {
        let path = Path::new("/nonexistent-markive-dir/note.md");

        assert!(save_document(path, "content").is_err());
    }

    #[test]
    fn headings_get_deduplicated_anchor_ids() {
        let html = render_markdown("# My Heading!\n\n## My Heading!\n\n### Config `opts`\n");

        assert!(html.contains("<h1 id=\"my-heading\">"));
        assert!(html.contains("<h2 id=\"my-heading-1\">"));
        assert!(html.contains("<h3 id=\"config-opts\">"));
    }

    #[test]
    fn resolves_relative_markdown_links_against_the_base_directory() {
        let rendered = render_document("[next](notes/next.md)", Some(Path::new("/docs")));

        assert!(rendered.html().contains("href=\"/docs/notes/next.md\""));
        assert!(rendered.local_images().is_empty());
    }

    #[test]
    fn keeps_anchor_and_remote_links_untouched() {
        let markdown = "[a](#section)\n\n[b](https://example.com)\n\n[c](mailto:x@y.z)";

        let rendered = render_document(markdown, Some(Path::new("/docs")));

        assert!(rendered.html().contains("href=\"#section\""));
        assert!(rendered.html().contains("href=\"https://example.com\""));
        assert!(rendered.html().contains("href=\"mailto:x@y.z\""));
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

    #[test]
    fn allows_structural_html_elements() {
        let markdown = r#"<div class="container">
<figure>
  <img src="image.png" alt="Example">
  <figcaption>A caption</figcaption>
</figure>
<section id="intro">
  <article>Some content</article>
</section>
<details open>
  <summary>Details</summary>
  Hidden content
</details>
</div>"#;

        let html = render_markdown(markdown);

        assert!(html.contains("<div"));
        assert!(html.contains("class=\"container\""));
        assert!(html.contains("<figure"));
        assert!(html.contains("<figcaption>"));
        assert!(html.contains("<section"));
        assert!(html.contains("id=\"intro\""));
        assert!(html.contains("<article>"));
        assert!(html.contains("<details"));
        assert!(html.contains("open"));
        assert!(html.contains("<summary>"));
    }
}
