use omarchy_link::{
    ChannelError, GuestSessionState, NegotiatedSession, ProtocolError, ProtocolVersion,
    channel_status_value, negotiate_link_session, workspace_identity_from_command_line,
};
use serde_json::{Value, json};
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::process::{Command, Stdio};
use std::time::Duration;
use std::{fs, thread};

const IDENTITY: &str = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";

/// An in-memory channel: reads consume a scripted host reply, writes collect
/// the guest's outbound frames.
struct ScriptedChannel {
    inbound: io::Cursor<Vec<u8>>,
    outbound: Vec<u8>,
}

impl ScriptedChannel {
    fn replying(frames: &[Value]) -> Self {
        let mut inbound = Vec::new();
        for frame in frames {
            inbound.extend_from_slice(&omarchy_link::encode_json(frame).unwrap());
        }
        Self {
            inbound: io::Cursor::new(inbound),
            outbound: Vec::new(),
        }
    }

    fn raw(bytes: Vec<u8>) -> Self {
        Self {
            inbound: io::Cursor::new(bytes),
            outbound: Vec::new(),
        }
    }

    fn sent_hello(&self) -> Value {
        let mut decoder = omarchy_link::FrameDecoder::default();
        let payloads = decoder.push(&self.outbound).unwrap();
        assert_eq!(payloads.len(), 1, "the guest must send exactly one hello");
        omarchy_link::decode_json(&payloads[0]).unwrap()
    }
}

impl Read for ScriptedChannel {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        self.inbound.read(buffer)
    }
}

impl Write for ScriptedChannel {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        self.outbound.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn host_response(id: &str, minor: u32, capabilities: &[&str]) -> Value {
    json!({
        "type": "response",
        "id": id,
        "result": {
            "protocol": {"major": 1, "minor": minor},
            "server": {"name": "try-omarchy-host", "version": "0.0.1"},
            "capabilities": capabilities,
        },
    })
}

#[test]
fn command_line_identity_requires_one_canonical_launcher_value() {
    let argument = format!("tryomarchy.workspace_id={IDENTITY}");
    let command_line = format!("root=/dev/vda rw {argument} console=hvc0");
    assert_eq!(
        workspace_identity_from_command_line(&command_line),
        Some(IDENTITY.to_owned())
    );
    assert_eq!(
        workspace_identity_from_command_line("root=/dev/vda rw"),
        None
    );
    // Ambiguous, non-canonical, uppercase, and non-v4 values all fail closed.
    assert_eq!(
        workspace_identity_from_command_line(&format!("{argument} {argument}")),
        None
    );
    for invalid in [
        "tryomarchy.workspace_id=",
        "tryomarchy.workspace_id=not-a-uuid",
        "tryomarchy.workspace_id=AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE",
        "tryomarchy.workspace_id=aaaaaaaa-bbbb-1ccc-8ddd-eeeeeeeeeeee",
        "tryomarchy.workspace_id=aaaaaaaa-bbbb-4ccc-1ddd-eeeeeeeeeeee",
        "tryomarchy.workspace_id=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee0",
    ] {
        assert_eq!(
            workspace_identity_from_command_line(invalid),
            None,
            "{invalid}"
        );
    }
}

#[test]
fn handshake_carries_the_workspace_identity_and_binds_the_session() {
    let mut channel = ScriptedChannel::replying(&[host_response(
        "session-hello",
        0,
        &["calendar.calendars.list", "calendar.events.list"],
    )]);
    let state = negotiate_link_session(
        &mut channel,
        IDENTITY.to_owned(),
        "session-hello".to_owned(),
    )
    .unwrap();

    let hello = channel.sent_hello();
    assert_eq!(hello["method"], "session.hello");
    assert_eq!(hello["params"]["workspaceIdentity"], IDENTITY);
    assert_eq!(hello["params"]["protocol"], json!({"major": 1, "minor": 0}));
    match state {
        GuestSessionState::Available(session) => {
            assert_eq!(
                session.protocol_version,
                ProtocolVersion { major: 1, minor: 0 }
            );
            assert_eq!(session.capabilities.len(), 2);
        }
        other => panic!("expected an available session, got {other:?}"),
    }
}

#[test]
fn a_newer_host_serves_this_client_through_additive_negotiation() {
    // The host may advertise Capability names this older client has never
    // heard of; they are carried opaquely rather than rejected.
    let mut channel = ScriptedChannel::replying(&[host_response(
        "session-hello",
        0,
        &["calendar.calendars.list", "future.operation.v9"],
    )]);
    let state = negotiate_link_session(
        &mut channel,
        IDENTITY.to_owned(),
        "session-hello".to_owned(),
    )
    .unwrap();
    let GuestSessionState::Available(NegotiatedSession { capabilities, .. }) = state else {
        panic!("expected an available session");
    };
    assert!(
        capabilities
            .iter()
            .any(|c| c.as_str() == "future.operation.v9")
    );
}

#[test]
fn typed_host_failures_make_link_unavailable_with_their_reason() {
    let mut channel = ScriptedChannel::replying(&[json!({
        "type": "error",
        "id": "session-hello",
        "error": {
            "code": "session.invalid_workspace_identity",
            "message": "Omarchy Link Workspace identity is missing or invalid",
        },
    })]);
    let state = negotiate_link_session(
        &mut channel,
        IDENTITY.to_owned(),
        "session-hello".to_owned(),
    )
    .unwrap();
    let GuestSessionState::LinkUnavailable(failure) = state else {
        panic!("expected an unavailable session");
    };
    assert_eq!(failure.code.as_str(), "session.invalid_workspace_identity");
}

#[test]
fn an_incompatible_protocol_response_is_a_typed_unavailability() {
    let mut channel =
        ScriptedChannel::replying(&[host_response("session-hello", 0, &[]).tap_set_major(2)]);
    let state = negotiate_link_session(
        &mut channel,
        IDENTITY.to_owned(),
        "session-hello".to_owned(),
    )
    .unwrap();
    let GuestSessionState::LinkUnavailable(failure) = state else {
        panic!("expected an unavailable session");
    };
    assert_eq!(failure.code.as_str(), "session.invalid_response");
}

trait TapSetMajor {
    fn tap_set_major(self, major: u32) -> Value;
}

impl TapSetMajor for Value {
    fn tap_set_major(mut self, major: u32) -> Value {
        self["result"]["protocol"]["major"] = json!(major);
        self
    }
}

#[test]
fn channel_end_and_malformed_traffic_fail_without_a_session() {
    let mut closed = ScriptedChannel::replying(&[]);
    assert_eq!(
        negotiate_link_session(&mut closed, IDENTITY.to_owned(), "session-hello".to_owned()),
        Err(ChannelError::Closed)
    );

    let mut malformed = ScriptedChannel::raw(vec![0, 0, 0, 0]);
    assert_eq!(
        negotiate_link_session(
            &mut malformed,
            IDENTITY.to_owned(),
            "session-hello".to_owned()
        ),
        Err(ChannelError::Protocol(ProtocolError::EmptyFrame))
    );
}

#[test]
fn owner_status_reports_the_negotiated_host_session() {
    let root = std::path::PathBuf::from("/tmp").join(format!("link-chan-{}", std::process::id()));
    fs::create_dir(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    fs::create_dir(root.join("omarchy-link")).unwrap();
    fs::set_permissions(root.join("omarchy-link"), fs::Permissions::from_mode(0o700)).unwrap();
    let command_line = root.join("cmdline");
    fs::write(
        &command_line,
        format!("root=/dev/vda rw tryomarchy.workspace_id={IDENTITY} console=hvc0\n"),
    )
    .unwrap();
    let channel = root.join("channel.sock");
    let listener = UnixListener::bind(&channel).unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .args(["daemon", "--development-fake"])
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .env("XDG_RUNTIME_DIR", &root)
        .env("OMARCHY_LINK_CHANNEL", &channel)
        .env("OMARCHY_LINK_CMDLINE", &command_line)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    // Serve the handshake as the host bridge would, with bounded readiness
    // so a daemon that never connects fails the test instead of hanging it.
    listener.set_nonblocking(true).unwrap();
    let mut accepted = None;
    for _ in 0..200 {
        match listener.accept() {
            Ok((stream, _)) => {
                accepted = Some(stream);
                break;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(50));
            }
            Err(error) => panic!("channel accept failed: {error}"),
        }
    }
    let mut stream = accepted.expect("the daemon never connected to the channel");
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut decoder = omarchy_link::FrameDecoder::default();
    let mut hello = None;
    let mut chunk = [0_u8; 4096];
    while hello.is_none() {
        let count = stream.read(&mut chunk).unwrap();
        assert_ne!(count, 0, "the daemon closed the channel before its hello");
        if let Some(payload) = decoder.push(&chunk[..count]).unwrap().into_iter().next() {
            hello = Some(omarchy_link::decode_json(&payload).unwrap());
        }
    }
    let hello = hello.unwrap();
    assert_eq!(hello["method"], "session.hello");
    assert_eq!(hello["params"]["workspaceIdentity"], IDENTITY);
    let hello_id = hello["id"].as_str().unwrap();
    assert!(
        hello_id.starts_with("hello-"),
        "hello identifiers must be unique per attempt, got {hello_id}"
    );
    let response = host_response(
        hello["id"].as_str().unwrap(),
        0,
        &["calendar.calendars.list"],
    );
    stream
        .write_all(&omarchy_link::encode_json(&response).unwrap())
        .unwrap();

    // The Owner-local status now reports the negotiated Link Session.
    let mut status = json!(null);
    for _ in 0..100 {
        let output = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
            .arg("status")
            .env("XDG_RUNTIME_DIR", &root)
            .output()
            .unwrap();
        if output.status.success() {
            status = serde_json::from_slice(&output.stdout).unwrap_or(json!(null));
            if status["available"] == true {
                break;
            }
        }
        thread::sleep(Duration::from_millis(50));
    }
    let _ = child.kill();
    let logs = child.wait_with_output().unwrap();
    fs::remove_dir_all(&root).unwrap();
    assert!(logs.stdout.is_empty());
    assert!(logs.stderr.is_empty());
    assert_eq!(status["available"], true, "{status}");
    assert_eq!(status["hostAvailable"], true);
    assert_eq!(status["capabilities"], json!(["calendar.calendars.list"]));
    assert_eq!(status["protocol"], json!({"major": 1, "minor": 0}));
    assert_eq!(status["adapter"], "invented");
}

#[test]
fn status_values_expose_typed_state_and_no_service_content() {
    let mut channel = ScriptedChannel::replying(&[host_response(
        "session-hello",
        0,
        &["calendar.calendars.list"],
    )]);
    let available = negotiate_link_session(
        &mut channel,
        IDENTITY.to_owned(),
        "session-hello".to_owned(),
    )
    .unwrap();
    assert_eq!(
        channel_status_value(&available),
        json!({
            "available": true,
            "hostAvailable": true,
            "protocol": {"major": 1, "minor": 0},
            "capabilities": ["calendar.calendars.list"],
        })
    );

    let mut failed = ScriptedChannel::replying(&[json!({
        "type": "error",
        "id": "session-hello",
        "error": {"code": "session.unsupported_protocol", "message": "unsupported"},
    })]);
    let unavailable =
        negotiate_link_session(&mut failed, IDENTITY.to_owned(), "session-hello".to_owned())
            .unwrap();
    assert_eq!(
        channel_status_value(&unavailable),
        json!({
            "available": false,
            "hostAvailable": false,
            "reason": "session.unsupported_protocol",
            "protocol": {"major": 1, "minor": 0},
        })
    );
}
