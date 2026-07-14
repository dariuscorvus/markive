//! Command-line interface for the `markive` binary.
//!
//! Parsing happens before any Tauri initialization so headless commands
//! like `render` never touch the windowing system.

use std::io::Read;
use std::path::Path;

/// Usage text for `--help` and argument errors.
pub const HELP: &str = "\
Markive — Markdown viewer

Usage:
  markive [path]           Open a Markdown file in the app
  markive render [path]    Render Markdown to sanitized HTML on stdout
                           (reads stdin when no path is given)

Options:
  -h, --help       Show this help
  -V, --version    Show the version
";

/// A parsed invocation of the `markive` binary.
#[derive(Debug, Eq, PartialEq)]
pub enum Command {
    /// Launch the app, optionally opening a document.
    Gui { path: Option<String> },
    /// Render a file (or stdin) to HTML on stdout without a window.
    Render { path: Option<String> },
    /// Print usage.
    Help,
    /// Print the version.
    Version,
}

/// Parses command-line arguments, excluding the program name.
///
/// # Errors
///
/// Returns a message suitable for stderr when the arguments are not a
/// valid invocation.
pub fn parse(args: &[String]) -> Result<Command, String> {
    // LaunchServices historically passed -psn_* process serial numbers.
    let args: Vec<&String> = args.iter().filter(|arg| !arg.starts_with("-psn_")).collect();

    match args.first().map(|arg| arg.as_str()) {
        None => Ok(Command::Gui { path: None }),
        Some("-h" | "--help") => Ok(Command::Help),
        Some("-V" | "--version") => Ok(Command::Version),
        Some("render") => match args.len() {
            1 => Ok(Command::Render { path: None }),
            2 => Ok(Command::Render {
                path: Some(args[1].clone()),
            }),
            _ => Err("render takes at most one path".to_string()),
        },
        Some(option) if option.starts_with('-') => Err(format!("unknown option {option}")),
        Some(path) => {
            if args.len() > 1 {
                return Err("expected a single Markdown path".to_string());
            }
            Ok(Command::Gui {
                path: Some(path.to_string()),
            })
        }
    }
}

/// Renders the file at `path` — or stdin when `path` is `None` — to
/// sanitized HTML.
///
/// # Errors
///
/// Returns a message suitable for stderr when the input cannot be read
/// or is not valid UTF-8.
pub fn render(path: Option<&str>) -> Result<String, String> {
    let markdown = if let Some(path) = path {
        std::fs::read_to_string(path).map_err(|error| format!("Unable to read {path}: {error}"))?
    } else {
        let mut buffer = String::new();
        std::io::stdin()
            .read_to_string(&mut buffer)
            .map_err(|error| format!("Unable to read stdin: {error}"))?;
        buffer
    };

    Ok(markive_core::render_markdown(&markdown))
}

/// Checks that `path` names an existing Markdown file before the GUI
/// starts.
///
/// # Errors
///
/// Returns a message suitable for stderr when the path is missing or
/// not a Markdown file.
pub fn validate_document_path(path: &str) -> Result<(), String> {
    let candidate = Path::new(path);

    if !candidate.is_file() {
        return Err(format!("{path} is not a file"));
    }
    if !markive_core::is_markdown_path(candidate) {
        return Err(format!("{path} is not a Markdown file"));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(ToString::to_string).collect()
    }

    #[test]
    fn no_arguments_launches_the_gui() {
        assert_eq!(parse(&[]), Ok(Command::Gui { path: None }));
    }

    #[test]
    fn a_path_launches_the_gui_with_the_document() {
        assert_eq!(
            parse(&args(&["notes.md"])),
            Ok(Command::Gui {
                path: Some("notes.md".to_string())
            })
        );
    }

    #[test]
    fn psn_arguments_are_ignored() {
        assert_eq!(
            parse(&args(&["-psn_0_12345"])),
            Ok(Command::Gui { path: None })
        );
    }

    #[test]
    fn render_without_a_path_reads_stdin() {
        assert_eq!(parse(&args(&["render"])), Ok(Command::Render { path: None }));
    }

    #[test]
    fn render_with_a_path() {
        assert_eq!(
            parse(&args(&["render", "notes.md"])),
            Ok(Command::Render {
                path: Some("notes.md".to_string())
            })
        );
    }

    #[test]
    fn render_rejects_extra_arguments() {
        assert!(parse(&args(&["render", "a.md", "b.md"])).is_err());
    }

    #[test]
    fn multiple_paths_are_rejected() {
        assert!(parse(&args(&["a.md", "b.md"])).is_err());
    }

    #[test]
    fn unknown_options_are_rejected() {
        assert!(parse(&args(&["--watch"])).is_err());
    }

    #[test]
    fn help_and_version_flags() {
        assert_eq!(parse(&args(&["--help"])), Ok(Command::Help));
        assert_eq!(parse(&args(&["-h"])), Ok(Command::Help));
        assert_eq!(parse(&args(&["--version"])), Ok(Command::Version));
        assert_eq!(parse(&args(&["-V"])), Ok(Command::Version));
    }
}
