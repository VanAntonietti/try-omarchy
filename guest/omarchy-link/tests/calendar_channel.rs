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
        .set_read_timeout(Some(Duration::from_secs(3)))
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
fn owner_queries_calendar_and_lock_blocks_content_without_logging_it() {
    let root = std::path::PathBuf::from(format!("/tmp/link-calendar-{}", std::process::id()));
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(
        root.join("cmdline"),
        "tryomarchy.workspace_id=12345678-1234-4234-8234-123456789abc",
    )
    .unwrap();
    fs::write(root.join("unlocked"), "yes").unwrap();
    let listener = UnixListener::bind(root.join("host")).unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .args(["daemon", "--development-fake"])
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .env("XDG_RUNTIME_DIR", &root)
        .env("OMARCHY_LINK_CHANNEL", root.join("host"))
        .env("OMARCHY_LINK_CMDLINE", root.join("cmdline"))
        .env("OMARCHY_LINK_UNLOCKED_FILE", root.join("unlocked"))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let result = std::panic::catch_unwind(|| {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut host = loop {
            match listener.accept() {
                Ok((s, _)) => break s,
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(10)),
                Err(e) => panic!("{e}"),
            }
        };
        host.set_nonblocking(false).unwrap();
        let hello = receive(&mut host);
        send(
            &mut host,
            json!({"type":"response","id":hello["id"],"result":{"server":{"name":"invented","version":"1"},"protocol":{"major":1,"minor":0},"capabilities":["calendar.calendars.list","calendar.events.list"]}}),
        );
        let call = |request: Value| {
            let mut s = UnixStream::connect(root.join("omarchy-link/socket")).unwrap();
            send(&mut s, request);
            receive(&mut s)
        };
        let deadline = Instant::now() + Duration::from_secs(3);
        while call(json!({"method":"status"}))["available"] != true {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        thread::scope(|scope| {
            let query = scope.spawn(|| call(json!({"method":"calendar.calendars.list"})));
            let request = receive(&mut host);
            assert_eq!(request["method"], "calendar.calendars.list");
            send(
                &mut host,
                json!({"type":"response","id":request["id"],"result":{"calendars":[{"id":"disposable","title":"Invented private calendar"}]}}),
            );
            assert_eq!(
                query.join().unwrap()["calendars"][0]["title"],
                "Invented private calendar"
            );
        });
        thread::scope(|scope| {
            let query = scope.spawn(|| call(json!({"method":"calendar.events.list", "start":"2026-11-01T04:00:00Z", "end":"2026-11-08T05:00:00Z", "calendarIds":["disposable"]})));
            let request = receive(&mut host);
            assert_eq!(
                request["params"],
                json!({"start":"2026-11-01T04:00:00Z", "end":"2026-11-08T05:00:00Z", "calendarIds":["disposable"]})
            );
            fs::write(root.join("unlocked"), "no").unwrap();
            send(
                &mut host,
                json!({"type":"response","id":request["id"],"result":{"events":[{"id":"event","calendarId":"disposable","title":"Invented secret", "startsAt":"2026-11-01T06:00:00Z","endsAt":"2026-11-01T07:00:00Z","allDay":false}]}}),
            );
            assert_eq!(query.join().unwrap()["error"]["code"], "session.locked");
        });
        send(
            &mut host,
            json!({"type":"event", "event":"invalidation", "service":"calendar"}),
        );
        let deadline = Instant::now() + Duration::from_secs(3);
        while call(json!({"method":"status"}))["calendarRevision"] != 1 {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(
            call(json!({"method":"calendar.calendars.list"}))["error"]["code"],
            "session.locked"
        );
        assert_eq!(call(json!({"method":"status"}))["contentAllowed"], false);
        fs::write(root.join("unlocked"), "yes").unwrap();
        thread::scope(|scope| {
            let query = scope.spawn(|| call(json!({"method":"calendar.calendars.list"})));
            let _ = receive(&mut host);
            drop(host);
            assert!(query.join().unwrap().get("error").is_some());
        });
    });
    let _ = child.kill();
    let logs = child.wait_with_output().unwrap();
    fs::remove_dir_all(root).unwrap();
    assert!(logs.stdout.is_empty());
    assert!(logs.stderr.is_empty());
    result.unwrap();
}
