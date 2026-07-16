#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::IsTerminal;
use std::process::ExitCode;

use markive_lib::cli::{self, Command};
use markive_lib::Launch;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match cli::parse(&args) {
        Ok(Command::Help) => {
            print!("{}", cli::HELP);
            ExitCode::SUCCESS
        }
        Ok(Command::Version) => {
            println!("markive {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Ok(Command::Render { path }) => match cli::render(path.as_deref()) {
            Ok(html) => {
                print!("{html}");
                ExitCode::SUCCESS
            }
            Err(message) => fail(&message),
        },
        Ok(Command::Gui { path }) => match path {
            // Piped stdin with no path behaves like `markive -`.
            None if !std::io::stdin().is_terminal() => launch_stdin(),
            None => launch_gui(Launch::Window),
            // A folder opens as a filesystem root; anything else must be
            // a Markdown document.
            Some(path) if std::path::Path::new(&path).is_dir() => {
                match cli::absolute_folder_path(&path) {
                    Ok(absolute) => launch_gui(Launch::Folder(absolute)),
                    Err(message) => fail(&message),
                }
            }
            Some(path) => match cli::absolute_document_path(&path) {
                Ok(absolute) => launch_gui(Launch::Document(absolute)),
                Err(message) => fail(&message),
            },
        },
        Ok(Command::GuiStdin) => launch_stdin(),
        Ok(Command::GuiStdinFile { file }) => {
            markive_lib::run(Launch::StdinFile(file));
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("markive: {message}\n\n{}", cli::HELP);
            ExitCode::from(2)
        }
    }
}

fn launch_stdin() -> ExitCode {
    match cli::stash_stdin() {
        Ok(Some(file)) => launch_gui(Launch::StdinFile(file)),
        Ok(None) => launch_gui(Launch::Window),
        Err(message) => fail(&message),
    }
}

/// Runs the app detached from the terminal, like `open` does. Launches
/// in-process when there is no terminal to detach from — Finder starts
/// the app that must receive its open-file events — or when this is
/// already the detached child.
fn launch_gui(launch: Launch) -> ExitCode {
    let child_process = std::env::var_os("MARKIVE_FOREGROUND").is_some();
    if child_process || !std::io::stderr().is_terminal() {
        markive_lib::run(launch);
        return ExitCode::SUCCESS;
    }

    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => return fail(&format!("Unable to find the markive binary: {error}")),
    };

    let mut command = std::process::Command::new(exe);
    match &launch {
        Launch::Window => {}
        Launch::Document(path) | Launch::Folder(path) => {
            command.arg(path);
        }
        Launch::StdinFile(file) => {
            command.args(["--stdin-file", file]);
        }
    }
    command
        .env("MARKIVE_FOREGROUND", "1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());

    // A new process group survives the terminal closing.
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }

    match command.spawn() {
        Ok(_) => ExitCode::SUCCESS,
        Err(error) => fail(&format!("Unable to launch Markive: {error}")),
    }
}

fn fail(message: &str) -> ExitCode {
    eprintln!("markive: {message}");
    ExitCode::FAILURE
}
