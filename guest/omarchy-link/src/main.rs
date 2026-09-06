use serde_json::json;
use std::env;
use std::process::ExitCode;

fn usage() {
    eprintln!("usage: omarchy-link <daemon|call|status>");
}

fn main() -> ExitCode {
    match env::args().nth(1).as_deref() {
        Some("status") => {
            println!(
                "{}",
                json!({
                    "available": false,
                    "protocol": { "major": 1, "minor": 0 },
                    "reason": "fake-data protocol peer only"
                })
            );
            ExitCode::SUCCESS
        }
        Some("daemon") | Some("call") => {
            eprintln!("omarchy-link: command is not implemented in the protocol scaffold");
            ExitCode::from(69)
        }
        _ => {
            usage();
            ExitCode::from(64)
        }
    }
}
