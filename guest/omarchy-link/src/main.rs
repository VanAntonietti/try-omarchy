use omarchy_link::{AgendaRange, DevelopmentAgendaBroker, InventedCalendarHostAdapter};
use serde_json::json;
use std::env;
use std::process::ExitCode;
use std::str::FromStr;

fn usage() {
    eprintln!(
        "usage: omarchy-link <daemon|call|status|demo-agenda --date YYYY-MM-DD --range today|seven-days [--calendar ID]>"
    );
}

fn main() -> ExitCode {
    let mut arguments = env::args().skip(1);
    match arguments.next().as_deref() {
        Some("status") if arguments.next().is_none() => {
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
        Some("demo-agenda") => demo_agenda(arguments.collect()),
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

fn demo_agenda(arguments: Vec<String>) -> ExitCode {
    if env::var("OMARCHY_LINK_DEVELOPMENT").as_deref() != Ok("1") {
        eprintln!("omarchy-link: the invented-data agenda requires OMARCHY_LINK_DEVELOPMENT=1");
        return ExitCode::from(69);
    }

    let mut date = None;
    let mut range = None;
    let mut calendar = None;
    let mut index = 0;
    while index < arguments.len() {
        let option = arguments[index].as_str();
        let Some(value) = arguments.get(index + 1) else {
            usage();
            return ExitCode::from(64);
        };
        match option {
            "--date" if date.is_none() => date = Some(value.as_str()),
            "--range" if range.is_none() => range = Some(value.as_str()),
            "--calendar" if calendar.is_none() => calendar = Some(value.as_str()),
            _ => {
                usage();
                return ExitCode::from(64);
            }
        }
        index += 2;
    }

    let (Some(date), Some(range)) = (date, range) else {
        usage();
        return ExitCode::from(64);
    };
    let range = match AgendaRange::from_str(range) {
        Ok(range) => range,
        Err(error) => {
            eprintln!("omarchy-link: {error}");
            return ExitCode::from(64);
        }
    };
    match DevelopmentAgendaBroker::new(InventedCalendarHostAdapter).agenda(date, range, calendar) {
        Ok(snapshot) => match serde_json::to_string(&snapshot) {
            Ok(encoded) => {
                println!("{encoded}");
                ExitCode::SUCCESS
            }
            Err(_) => {
                eprintln!("omarchy-link: could not encode the invented agenda");
                ExitCode::from(70)
            }
        },
        Err(error) => {
            eprintln!("omarchy-link: {error}");
            ExitCode::from(64)
        }
    }
}
