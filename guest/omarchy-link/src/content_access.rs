//! Fail closed when logind or the supported Hyprland lock state is unknown.
use std::{
    env, fs,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn probe(program: &str, args: &[&str]) -> Option<std::process::Output> {
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + Duration::from_millis(200);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().ok(),
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

pub fn allowed(development: bool) -> bool {
    if development {
        if let Some(path) = env::var_os("OMARCHY_LINK_UNLOCKED_FILE") {
            return fs::read_to_string(path).is_ok_and(|value| value == "yes");
        }
    }
    // The user service has no login session of its own. Query the Owner's
    // graphical session, not `self`, and require both active and unlocked.
    let Some(session) = probe(
        "/usr/bin/loginctl",
        &["show-user", "1000", "--property=Display", "--value"],
    )
    .filter(|output| output.status.success())
    .and_then(|output| String::from_utf8(output.stdout).ok()) else {
        return false;
    };
    let session = session.trim();
    if session.is_empty() || !session.bytes().all(|c| c.is_ascii_alphanumeric()) {
        return false;
    }
    let Some(state) = probe(
        "/usr/bin/loginctl",
        &[
            "show-session",
            session,
            "--property=Active",
            "--property=LockedHint",
        ],
    )
    .filter(|output| output.status.success())
    .and_then(|output| String::from_utf8(output.stdout).ok()) else {
        return false;
    };
    if !state.lines().any(|line| line == "Active=yes")
        || !state.lines().any(|line| line == "LockedHint=no")
    {
        return false;
    }
    // Hyprlock need not publish LockedHint. Its presence also blocks content.
    probe("/usr/bin/pgrep", &["-u", "1000", "-x", "hyprlock"])
        .is_some_and(|output| output.status.code() == Some(1))
}
