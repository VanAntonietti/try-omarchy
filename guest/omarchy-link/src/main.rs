mod local;

use omarchy_link::{
    AgendaRange, CalendarCreateRequest, DevelopmentAgendaBroker, DevelopmentMutationBroker,
    InventedCalendarHostAdapter, ReviewDecision, ReviewInterlock, ReviewPresentation,
    ReviewUiState,
};
use serde_json::json;
use std::env;
use std::io::{self, IsTerminal, Write};
use std::process::{Command, ExitCode};
use std::str::FromStr;

fn usage() {
    eprintln!(
        "usage: omarchy-link <daemon|call|status|demo-agenda --date YYYY-MM-DD --range today|seven-days [--calendar ID]|demo-create --title TITLE --start UTC --end UTC --calendar ID>"
    );
}

fn main() -> ExitCode {
    let mut arguments = env::args().skip(1);
    match arguments.next().as_deref() {
        Some("status") if arguments.next().is_none() => {
            println!("{}", local::status());
            ExitCode::SUCCESS
        }
        Some("demo-agenda") => demo_agenda(arguments.collect()),
        Some("demo-create") => demo_create(arguments.collect()),
        Some("daemon") => {
            let args: Vec<_> = arguments.collect();
            let fake = args == ["--development-fake"];
            if !args.is_empty() && !fake {
                usage();
                return ExitCode::from(64);
            }
            match local::daemon(fake) {
                Ok(()) => ExitCode::SUCCESS,
                Err(_) => {
                    eprintln!("omarchy-link: broker unavailable");
                    ExitCode::from(69)
                }
            }
        }
        Some("call") if arguments.next().is_none() => {
            use std::io::Read;
            let mut input = Vec::new();
            if io::stdin().take(65537).read_to_end(&mut input).is_err() || input.len() > 65536 {
                return ExitCode::from(64);
            }
            let Ok(request) = serde_json::from_slice(&input) else {
                return ExitCode::from(64);
            };
            match local::client(request) {
                Ok(response) => {
                    println!("{response}");
                    ExitCode::SUCCESS
                }
                Err(_) => {
                    println!(
                        "{}",
                        json!({"error":{"code":"service.unavailable","message":"host Link unavailable"}})
                    );
                    ExitCode::from(69)
                }
            }
        }
        _ => {
            usage();
            ExitCode::from(64)
        }
    }
}

fn demo_create(arguments: Vec<String>) -> ExitCode {
    if env::var("OMARCHY_LINK_DEVELOPMENT").as_deref() != Ok("1") {
        eprintln!("omarchy-link: the invented-data review requires OMARCHY_LINK_DEVELOPMENT=1");
        return ExitCode::from(69);
    }

    let mut title = None;
    let mut start = None;
    let mut end = None;
    let mut calendar = None;
    let mut index = 0;
    while index < arguments.len() {
        let option = arguments[index].as_str();
        let Some(value) = arguments.get(index + 1) else {
            usage();
            return ExitCode::from(64);
        };
        match option {
            "--title" if title.is_none() => title = Some(value.clone()),
            "--start" if start.is_none() => start = Some(value.clone()),
            "--end" if end.is_none() => end = Some(value.clone()),
            "--calendar" if calendar.is_none() => calendar = Some(value.clone()),
            _ => {
                usage();
                return ExitCode::from(64);
            }
        }
        index += 2;
    }
    let (Some(title), Some(start), Some(end), Some(calendar_id)) = (title, start, end, calendar)
    else {
        usage();
        return ExitCode::from(64);
    };

    let request = CalendarCreateRequest {
        title,
        starts_at: start,
        ends_at: end,
        calendar_id,
    };
    let proposal =
        match DevelopmentMutationBroker::new(InventedCalendarHostAdapter).propose(&request) {
            Ok(proposal) => proposal,
            Err(error) => {
                eprintln!("omarchy-link: {error}");
                return ExitCode::from(64);
            }
        };
    let mut review = ReviewInterlock::new(proposal);
    let presentation = review.present(review_ui_state());
    let ReviewPresentation::Proposal(proposal) = presentation else {
        let ReviewPresentation::Blocked(result) = presentation else {
            unreachable!()
        };
        println!(
            "{}",
            serde_json::to_string(&result).expect("ReviewResult is JSON encodable")
        );
        return ExitCode::from(77);
    };

    print!("{}", proposal.review_text());
    println!("No host Calendar data will be written by this development demo.");
    print!("Approve this one Mutation Proposal? [y/N] ");
    if io::stdout().flush().is_err() {
        let result = review.resolve(ReviewDecision::Dismiss, ReviewUiState::Unavailable);
        println!(
            "{}",
            serde_json::to_string(&result).expect("ReviewResult is JSON encodable")
        );
        return ExitCode::SUCCESS;
    }
    let mut decision = String::new();
    let decision = match io::stdin().read_line(&mut decision) {
        Ok(0) | Err(_) => ReviewDecision::Dismiss,
        Ok(_) if matches!(decision.trim().to_ascii_lowercase().as_str(), "y" | "yes") => {
            ReviewDecision::Approve
        }
        Ok(_) => ReviewDecision::Reject,
    };
    let result = review.resolve(decision, review_ui_state());
    println!(
        "{}",
        serde_json::to_string(&result).expect("ReviewResult is JSON encodable")
    );
    ExitCode::SUCCESS
}

fn review_ui_state() -> ReviewUiState {
    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        return ReviewUiState::Headless;
    }
    if env::var_os("WAYLAND_DISPLAY").is_none() {
        return ReviewUiState::Unavailable;
    }
    let Ok(output) = Command::new("loginctl")
        .args(["show-session", "self", "--property=LockedHint", "--value"])
        .output()
    else {
        return ReviewUiState::Unavailable;
    };
    if !output.status.success() {
        return ReviewUiState::Unavailable;
    }
    match String::from_utf8_lossy(&output.stdout).trim() {
        "yes" => ReviewUiState::Locked,
        "no" => ReviewUiState::Available,
        _ => ReviewUiState::Unavailable,
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
