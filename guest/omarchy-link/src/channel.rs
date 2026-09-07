//! The guest side of one Link Session over the private VM channel.
//!
//! The transport is QEMU's multiplexed virtio-serial port; there is no TCP
//! listener, SSH dependency, or arbitrary command surface behind it. The
//! handshake binds the launcher-fixed Workspace identity from the kernel
//! command line; every failure is a typed unavailability, never a VM fault.

use crate::{
    ClientIdentity, FrameDecoder, GuestSession, GuestSessionState, ProtocolError, ProtocolVersion,
    decode_json, encode_json,
};
use serde_json::{Value, json};
use std::io::{Read, Write};

/// The virtio port the launcher attaches for a validated Workspace.
pub const CHANNEL_DEVICE: &str = "/dev/virtio-ports/dev.tryomarchy.link";

const KERNEL_ARGUMENT_PREFIX: &str = "tryomarchy.workspace_id=";

#[derive(Debug, Eq, PartialEq)]
pub enum ChannelError {
    /// The channel ended before the host settled the handshake.
    Closed,
    /// The transport failed while reading or writing.
    Io,
    /// The peer violated the framing or schema rules.
    Protocol(ProtocolError),
}

/// Extracts the launcher-fixed Workspace identity from the kernel command
/// line. Exactly one canonical lowercase UUIDv4 is accepted; anything else,
/// including a duplicated argument, fails closed.
pub fn workspace_identity_from_command_line(command_line: &str) -> Option<String> {
    let mut found = None;
    for argument in command_line.split_ascii_whitespace() {
        if let Some(value) = argument.strip_prefix(KERNEL_ARGUMENT_PREFIX) {
            if found.is_some() {
                return None;
            }
            found = Some(value);
        }
    }
    let value = found?;
    is_canonical_workspace_identity(value).then(|| value.to_owned())
}

fn is_canonical_workspace_identity(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 36 {
        return false;
    }
    bytes.iter().enumerate().all(|(index, byte)| match index {
        8 | 13 | 18 | 23 => *byte == b'-',
        14 => *byte == b'4',
        19 => matches!(byte, b'8' | b'9' | b'a' | b'b'),
        _ => matches!(byte, b'0'..=b'9' | b'a'..=b'f'),
    })
}

/// Sends `session.hello` bound to the Workspace identity and blocks until the
/// host settles the handshake or the channel ends. The returned state is
/// terminal for this connection: available with negotiated Capabilities, or
/// unavailable with a typed reason.
///
/// The caller supplies a request identifier that is unique per attempt: the
/// host remembers every identifier for the whole Link Session, so a reused
/// one would turn a retried handshake into a terminal protocol violation
/// instead of the typed `session.handshake_already_complete` failure.
pub fn negotiate_link_session(
    transport: &mut (impl Read + Write),
    workspace_identity: String,
    request_id: String,
) -> Result<GuestSessionState, ChannelError> {
    let mut session = GuestSession::new(
        request_id,
        ClientIdentity {
            name: "omarchy-link".to_owned(),
            version: env!("CARGO_PKG_VERSION").to_owned(),
        },
        ProtocolVersion { major: 1, minor: 0 },
    )
    .with_workspace_identity(workspace_identity);

    let hello = encode_json(&session.hello_request()).map_err(ChannelError::Protocol)?;
    transport.write_all(&hello).map_err(|_| ChannelError::Io)?;
    transport.flush().map_err(|_| ChannelError::Io)?;

    let mut decoder = FrameDecoder::default();
    let mut chunk = [0_u8; 4096];
    loop {
        let count = transport.read(&mut chunk).map_err(|_| ChannelError::Io)?;
        if count == 0 {
            return Err(ChannelError::Closed);
        }
        for payload in decoder
            .push(&chunk[..count])
            .map_err(ChannelError::Protocol)?
        {
            let reply = decode_json(&payload).map_err(ChannelError::Protocol)?;
            let state = session.accept_handshake(&reply).clone();
            if state != GuestSessionState::AwaitingHandshake {
                return Ok(state);
            }
        }
    }
}

/// The bounded, content-free status the Owner-local broker reports for the
/// host channel. Capabilities are advertised names, never service data.
pub fn channel_status_value(state: &GuestSessionState) -> Value {
    match state {
        GuestSessionState::Available(session) => json!({
            "available": true,
            "hostAvailable": true,
            "protocol": {
                "major": session.protocol_version.major,
                "minor": session.protocol_version.minor,
            },
            "capabilities": session
                .capabilities
                .iter()
                .map(|capability| capability.as_str())
                .collect::<Vec<_>>(),
        }),
        GuestSessionState::LinkUnavailable(failure) => json!({
            "available": false,
            "hostAvailable": false,
            "reason": failure.code.as_str(),
            "protocol": {"major": 1, "minor": 0},
        }),
        GuestSessionState::AwaitingHandshake => json!({
            "available": false,
            "hostAvailable": false,
            "reason": "session.handshake_required",
            "protocol": {"major": 1, "minor": 0},
        }),
    }
}
