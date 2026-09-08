use omarchy_link::{CalendarCreateOutcome, GuestPeer, PeerMessage, encode_json};
use serde_json::json;

#[test]
fn supported_cli_refuses_headless_creation_and_call_cannot_approve() {
    use std::{
        io::Write,
        process::{Command, Stdio},
    };
    let result = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .arg("create-calendar")
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .env("WAYLAND_DISPLAY", "invented")
        .output()
        .unwrap();
    assert_eq!(result.status.code(), Some(77));
    let mut child = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .arg("call")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"{\"method\":\"calendar.create\",\"approved\":true}")
        .unwrap();
    assert_eq!(child.wait_with_output().unwrap().status.code(), Some(77));
}

#[test]
fn graphical_cli_accepts_a_request_without_a_development_flag() {
    // A PTY is the CLI's public interactive boundary. No actual review or host
    // exists here: reaching IPC returns uncertainty rather than gate refusal.
    let output = std::process::Command::new("python3")
        .args(["-c", r#"
import os, pty, subprocess, sys
master, terminal = pty.openpty()
try:
    result = subprocess.run([sys.argv[1], 'create-calendar'],
        input=b'{"title":"Invented","startsAt":"2026-09-14T09:00:00Z","endsAt":"2026-09-14T10:00:00Z","calendarId":"invented"}',
        stdout=terminal, stderr=subprocess.PIPE, timeout=5)
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert b'uncertain' in os.read(master, 4096)
finally:
    os.close(master)
    os.close(terminal)
"#, env!("CARGO_BIN_EXE_omarchy-link")])
        .env_remove("OMARCHY_LINK_DEVELOPMENT")
        .env_remove("XDG_RUNTIME_DIR")
        .env("WAYLAND_DISPLAY", "invented")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn create_outcome_is_correlated_and_disconnect_cannot_replay() {
    let mut peer = GuestPeer::new();
    peer.hello_frame().unwrap();
    peer.receive(
        &encode_json(&json!({"type":"response","id":"hello","result":{
            "protocol":{"major":1,"minor":0},"server":{"name":"invented","version":"1"},
            "capabilities":["calendar.events.create.perform"]
        }}))
        .unwrap(),
    )
    .unwrap();
    let (id, _) = peer.perform_calendar_event("invented-proposal").unwrap();
    let messages = peer
        .receive(
            &encode_json(&json!({"type":"response","id":id,
        "result":{"outcome":"uncertain"}}))
            .unwrap(),
        )
        .unwrap();
    assert!(
        matches!(&messages[0], PeerMessage::MutationPerformed { outcome, .. } if *outcome == CalendarCreateOutcome::Uncertain)
    );
    peer.finish().unwrap();
    assert!(peer.perform_calendar_event("invented-proposal").is_err());
}
