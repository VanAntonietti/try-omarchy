use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    os::unix::{
        fs::PermissionsExt,
        net::{UnixListener, UnixStream},
    },
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn receive(stream: &mut UnixStream) -> Value {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut header = [0; 4];
    stream.read_exact(&mut header).unwrap();
    let mut body = vec![0; u32::from_be_bytes(header) as usize];
    stream.read_exact(&mut body).unwrap();
    serde_json::from_slice(&body).unwrap()
}
fn send(stream: &mut UnixStream, value: Value) {
    stream
        .write_all(&omarchy_link::encode_json(&value).unwrap())
        .unwrap();
}

#[test]
fn broker_executes_only_after_its_visible_review_and_never_exposes_perform() {
    exercise("approve");
}
#[test]
fn rejected_review_performs_nothing() {
    exercise("reject");
}
#[test]
fn lock_during_review_performs_nothing() {
    exercise("lock");
}
#[test]
fn missing_review_ui_performs_nothing() {
    exercise("missing-ui");
}
#[test]
fn disconnect_after_submission_reports_uncertainty_without_replay() {
    exercise("disconnect");
}
#[test]
fn disconnect_during_review_performs_nothing() {
    exercise("disconnect-review");
}

fn exercise(scenario: &str) {
    let root = std::path::PathBuf::from(format!(
        "/tmp/link-create-{}-{scenario}",
        std::process::id()
    ));
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(
        root.join("cmdline"),
        "tryomarchy.workspace_id=12345678-1234-4234-8234-123456789abc",
    )
    .unwrap();
    fs::write(root.join("unlocked"), "yes").unwrap();
    // A system-boundary fixture consumes the canonical proposal over stdin.
    fs::write(
        root.join("review"),
        "#!/bin/sh\n/usr/bin/grep -q 'Invented canonical'\n",
    )
    .unwrap();
    if scenario == "reject" {
        fs::write(root.join("review"), "#!/bin/sh\nexit 1\n").unwrap();
    }
    if matches!(scenario, "lock" | "disconnect-review") {
        fs::write(root.join("review"), format!("#!/bin/sh\n/usr/bin/grep -q 'Invented canonical' || exit 1\ntouch '{}'\nsleep 20\n", root.join("presented").display())).unwrap();
    }
    fs::set_permissions(root.join("review"), fs::Permissions::from_mode(0o700)).unwrap();
    if scenario == "missing-ui" {
        fs::remove_file(root.join("review")).unwrap();
    }
    let listener = UnixListener::bind(root.join("host")).unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .args(["daemon", "--development-fake"])
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .env("XDG_RUNTIME_DIR", &root)
        .env("OMARCHY_LINK_CHANNEL", root.join("host"))
        .env("OMARCHY_LINK_CMDLINE", root.join("cmdline"))
        .env("OMARCHY_LINK_UNLOCKED_FILE", root.join("unlocked"))
        .env("OMARCHY_LINK_REVIEW_FIXTURE", root.join("review"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let result = std::panic::catch_unwind(|| {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut host = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
                Err(error) => panic!("{error}"),
            }
        };
        host.set_nonblocking(false).unwrap();
        let hello = receive(&mut host);
        send(
            &mut host,
            json!({"type":"response", "id":hello["id"], "result":{
                "protocol":{"major":1,"minor":0}, "server":{"name":"invented","version":"1"},
                "capabilities":["calendar.events.create.propose","calendar.events.create.perform"]
            }}),
        );
        let call = |request: Value| {
            let mut client = UnixStream::connect(root.join("omarchy-link/socket")).unwrap();
            send(&mut client, request);
            receive(&mut client)
        };
        while call(json!({"method":"status"}))["available"] != true {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        assert!(
            call(json!({"method":"calendar.events.create.perform", "proposalId":"forged"}))
                .get("error")
                .is_some()
        );
        let request = json!({"method":"calendar.create", "title":"Invented request", "startsAt":"2026-09-14T09:00:00Z", "endsAt":"2026-09-14T10:00:00Z", "calendarId":"invented"});
        thread::scope(|scope| {
            let result = scope.spawn(|| call(request.clone()));
            let proposal = receive(&mut host);
            assert_eq!(proposal["method"], "calendar.events.create.propose");
            send(
                &mut host,
                json!({"type":"response","id":proposal["id"],"result":{"proposal":{
                    "id":"one-shot", "service":"calendar", "operation":"event.create", "title":"Invented canonical",
                    "startsAt":"2026-09-14T09:00:00Z", "endsAt":"2026-09-14T10:00:00Z",
                    "calendar":{"id":"invented","title":"Invented calendar"}
                }}}),
            );
            if matches!(scenario, "lock" | "disconnect-review") {
                let deadline = Instant::now() + Duration::from_secs(3);
                while !root.join("presented").exists() {
                    assert!(Instant::now() < deadline);
                    thread::sleep(Duration::from_millis(10));
                }
                if scenario == "lock" {
                    fs::write(root.join("unlocked"), "no").unwrap();
                } else {
                    host.shutdown(std::net::Shutdown::Both).unwrap();
                }
            }
            if matches!(scenario, "approve" | "disconnect") {
                let perform = receive(&mut host);
                assert_eq!(perform["method"], "calendar.events.create.perform");
                assert_eq!(perform["params"], json!({"proposalId":"one-shot"}));
                if scenario == "disconnect" {
                    host.shutdown(std::net::Shutdown::Both).unwrap();
                    assert_eq!(result.join().unwrap()["outcome"], "uncertain");
                } else {
                    send(
                        &mut host,
                        json!({"type":"response","id":perform["id"],"result":{"outcome":"succeeded"}}),
                    );
                    assert_eq!(result.join().unwrap()["outcome"], "succeeded");
                }
            } else {
                assert_eq!(result.join().unwrap()["outcome"], "failed");
                if scenario != "disconnect-review" {
                    host.set_read_timeout(Some(Duration::from_millis(100)))
                        .unwrap();
                }
                let mut byte = [0];
                assert!(!matches!(host.read(&mut byte), Ok(1)));
            }
        });
        fs::write(root.join("unlocked"), "no").unwrap();
        assert_eq!(call(request)["error"]["code"], "session.locked");
    });
    let _ = child.kill();
    let logs = child.wait_with_output().unwrap();
    fs::remove_dir_all(root).unwrap();
    assert!(logs.stdout.is_empty() && logs.stderr.is_empty());
    result.unwrap();
}
