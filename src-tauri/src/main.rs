#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::process::ExitCode;

use markive_lib::cli::{self, Command};

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
            Err(message) => {
                eprintln!("markive: {message}");
                ExitCode::FAILURE
            }
        },
        Ok(Command::Gui { path }) => {
            if let Some(path) = &path
                && let Err(message) = cli::validate_document_path(path)
            {
                eprintln!("markive: {message}");
                return ExitCode::FAILURE;
            }
            markive_lib::run(path);
            ExitCode::SUCCESS
        }
        Err(message) => {
            eprintln!("markive: {message}\n\n{}", cli::HELP);
            ExitCode::from(2)
        }
    }
}
