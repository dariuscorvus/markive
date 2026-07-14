//! End-to-end tests for the `markive` CLI, running the real binary.

use std::io::Write;
use std::process::{Command, Stdio};

fn markive() -> Command {
    Command::new(env!("CARGO_BIN_EXE_markive"))
}

#[test]
fn render_prints_sanitized_html_for_a_file() {
    let path = std::env::temp_dir().join(format!("markive-cli-{}.md", std::process::id()));
    std::fs::write(&path, "# Title\n\n<script>alert('no')</script>\n").expect("write test file");

    let output = markive()
        .arg("render")
        .arg(&path)
        .output()
        .expect("run markive render");

    let stdout = String::from_utf8(output.stdout).expect("stdout is UTF-8");
    assert!(output.status.success());
    assert!(stdout.contains("<h1 id=\"title\">Title</h1>"));
    assert!(!stdout.contains("<script"));

    std::fs::remove_file(&path).expect("remove test file");
}

#[test]
fn render_reads_stdin_in_a_pipe() {
    let mut child = markive()
        .arg("render")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("spawn markive render");

    child
        .stdin
        .take()
        .expect("stdin handle")
        .write_all(b"*piped*\n")
        .expect("write to stdin");

    let output = child.wait_with_output().expect("wait for markive");
    let stdout = String::from_utf8(output.stdout).expect("stdout is UTF-8");

    assert!(output.status.success());
    assert!(stdout.contains("<em>piped</em>"));
}

#[test]
fn render_reports_missing_files_on_stderr() {
    let output = markive()
        .args(["render", "/nonexistent/markive.md"])
        .output()
        .expect("run markive render");

    let stderr = String::from_utf8(output.stderr).expect("stderr is UTF-8");
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    assert!(stderr.contains("Unable to read /nonexistent/markive.md"));
}

#[test]
fn opening_a_missing_document_fails_before_the_gui_starts() {
    let output = markive()
        .arg("/nonexistent/markive.md")
        .output()
        .expect("run markive");

    let stderr = String::from_utf8(output.stderr).expect("stderr is UTF-8");
    assert!(!output.status.success());
    assert!(stderr.contains("is not a file"));
}

#[test]
fn opening_a_non_markdown_file_fails_before_the_gui_starts() {
    let path = std::env::temp_dir().join(format!("markive-cli-{}.txt", std::process::id()));
    std::fs::write(&path, "plain text").expect("write test file");

    let output = markive().arg(&path).output().expect("run markive");

    let stderr = String::from_utf8(output.stderr).expect("stderr is UTF-8");
    assert!(!output.status.success());
    assert!(stderr.contains("is not a Markdown file"));

    std::fs::remove_file(&path).expect("remove test file");
}

#[test]
fn version_and_help() {
    let version = markive().arg("--version").output().expect("run markive");
    assert!(version.status.success());
    assert!(
        String::from_utf8(version.stdout)
            .expect("stdout is UTF-8")
            .starts_with("markive ")
    );

    let help = markive().arg("--help").output().expect("run markive");
    assert!(help.status.success());
    assert!(
        String::from_utf8(help.stdout)
            .expect("stdout is UTF-8")
            .contains("Usage:")
    );
}

#[test]
fn unknown_options_exit_with_usage_error() {
    let output = markive().arg("--watch").output().expect("run markive");

    assert_eq!(output.status.code(), Some(2));
    assert!(
        String::from_utf8(output.stderr)
            .expect("stderr is UTF-8")
            .contains("unknown option --watch")
    );
}
