//! The full document lifecycle and its failure states (#18): open,
//! edit, save, reopen, Save As, and every way the filesystem can say
//! no.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

fn temp_path(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("markive-lifecycle-{}-{name}", std::process::id()))
}

#[test]
fn open_edit_save_reopen_round_trip() {
    let path = temp_path("round-trip.md");
    std::fs::write(&path, "# Original\n").expect("write document");

    let document = markive_core::open_document(&path).expect("open");
    assert_eq!(document.content(), "# Original\n");

    // Edit and save in place.
    let edited = "# Original\n\nEdited paragraph.\n";
    markive_core::save_document(&path, edited).expect("save");

    let reopened = markive_core::open_document(&path).expect("reopen");
    assert_eq!(reopened.content(), edited);

    std::fs::remove_file(&path).expect("remove document");
}

#[test]
fn save_as_writes_a_new_file_and_leaves_the_original() {
    let original = temp_path("save-as-original.md");
    let copy = temp_path("save-as-copy.md");
    std::fs::write(&original, "# Original\n").expect("write document");

    let document = markive_core::open_document(&original).expect("open");
    let edited = format!("{}\nMore.\n", document.content());

    // Save As: the edited buffer goes to a new path; the original
    // file keeps its content.
    markive_core::save_document(&copy, &edited).expect("save as");

    assert_eq!(
        markive_core::open_document(&copy).expect("open copy").content(),
        edited
    );
    assert_eq!(
        markive_core::open_document(&original)
            .expect("open original")
            .content(),
        "# Original\n"
    );

    std::fs::remove_file(&original).expect("remove original");
    std::fs::remove_file(&copy).expect("remove copy");
}

#[test]
fn opening_invalid_utf8_fails_without_mangling() {
    let path = temp_path("invalid-utf8.md");
    std::fs::write(&path, [0x23, 0x20, 0xff, 0xfe, 0x0a]).expect("write bytes");

    let error = markive_core::open_document(&path).expect_err("reject invalid UTF-8");
    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);

    // The file on disk is untouched.
    assert_eq!(
        std::fs::read(&path).expect("read bytes"),
        [0x23, 0x20, 0xff, 0xfe, 0x0a]
    );

    std::fs::remove_file(&path).expect("remove file");
}

#[test]
fn opening_a_missing_file_fails() {
    let error = markive_core::open_document(temp_path("never-created.md"))
        .expect_err("reject missing file");
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
}

#[test]
fn opening_an_unreadable_file_fails() {
    let path = temp_path("unreadable.md");
    std::fs::write(&path, "# Secret\n").expect("write document");
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000))
        .expect("drop permissions");

    let error = markive_core::open_document(&path).expect_err("reject unreadable file");
    assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);

    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644))
        .expect("restore permissions");
    std::fs::remove_file(&path).expect("remove file");
}

#[test]
fn saving_into_a_missing_directory_fails_cleanly() {
    let path = temp_path("no-such-dir").join("document.md");

    let error = markive_core::save_document(&path, "# Content\n").expect_err("reject missing dir");
    assert_eq!(error.kind(), std::io::ErrorKind::NotFound);
}

#[test]
fn saving_into_an_unwritable_directory_fails_and_leaves_no_temp_files() {
    let dir = temp_path("unwritable-dir");
    std::fs::create_dir(&dir).expect("create dir");
    let path = dir.join("document.md");
    std::fs::write(&path, "# Before\n").expect("write document");
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o555))
        .expect("make dir read-only");

    let error = markive_core::save_document(&path, "# After\n").expect_err("reject unwritable dir");
    assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);

    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755))
        .expect("restore permissions");

    // The original survives and no atomic-write temp file is left behind.
    assert_eq!(
        std::fs::read_to_string(&path).expect("read document"),
        "# Before\n"
    );
    assert_eq!(
        std::fs::read_dir(&dir).expect("list dir").count(),
        1,
        "temp file left behind"
    );

    std::fs::remove_dir_all(&dir).expect("remove dir");
}

/// Clipboard text renders like any pathless document: no base
/// directory, so only absolute local targets resolve.
#[test]
fn clipboard_text_renders_without_a_base_directory() {
    let rendered = markive_core::render_document("# Pasted\n\n![a](images/a.png)\n", None);

    assert!(rendered.html().contains("<h1 id=\"pasted\">Pasted</h1>"));
    assert!(rendered.html().contains("src=\"images/a.png\""));
    assert!(rendered.local_images().is_empty());
}

#[test]
fn sanitization_strips_active_content() {
    let vectors = [
        "<script>alert(1)</script>",
        "<img src=\"x.png\" onerror=\"alert(1)\">",
        "<a href=\"javascript:alert(1)\">x</a>",
        "<iframe src=\"https://example.com\"></iframe>",
        "<svg><script>alert(1)</script></svg>",
        "<div onclick=\"alert(1)\">x</div>",
        "<object data=\"x\"></object>",
        "<embed src=\"x\">",
    ];

    for vector in vectors {
        let html = markive_core::render_markdown(&format!("before\n\n{vector}\n\nafter\n"));
        for needle in ["<script", "onerror", "javascript:", "<iframe", "onclick", "<object", "<embed"] {
            assert!(
                !html.contains(needle),
                "sanitizer let {needle:?} through for vector {vector:?}: {html}"
            );
        }
    }
}
