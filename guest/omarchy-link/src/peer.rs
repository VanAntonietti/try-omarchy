use crate::{
    ClientIdentity, FrameDecoder, GuestSession, GuestSessionState, NegotiatedSession,
    ProtocolError, ProtocolVersion, SessionFailure, decode_json, encode_json,
};
use serde::Deserialize;
use serde_json::json;
use std::collections::HashSet;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct Calendar {
    pub id: String,
    pub title: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(try_from = "String")]
pub enum RequestFailureCode {
    ServiceUnavailable,
    Cancelled,
    MethodUnavailable,
    Busy,
    Unknown,
}

impl TryFrom<String> for RequestFailureCode {
    type Error = &'static str;

    fn try_from(code: String) -> Result<Self, Self::Error> {
        if code.is_empty() || code.len() > 128 {
            return Err("request error codes must contain 1–128 UTF-8 bytes");
        }
        Ok(match code.as_str() {
            "service.unavailable" => Self::ServiceUnavailable,
            "request.cancelled" => Self::Cancelled,
            "request.method_unavailable" => Self::MethodUnavailable,
            "request.busy" => Self::Busy,
            _ => Self::Unknown,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct RequestFailure {
    pub code: RequestFailureCode,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum MacService {
    Calendar,
    Messages,
    Notes,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PeerMessage {
    Invalidated(MacService),
    Ready(NegotiatedSession),
    Unavailable(SessionFailure),
    Calendars {
        id: String,
        calendars: Vec<Calendar>,
    },
    Failed {
        id: String,
        failure: RequestFailure,
    },
}

/// A fake-data protocol peer, not a daemon or a connection to a Mac Service.
pub struct GuestPeer {
    session: GuestSession,
    decoder: FrameDecoder,
    pending: HashSet<String>,
    next_id: u32,
    closed: bool,
    hello_sent: bool,
}

impl Default for GuestPeer {
    fn default() -> Self {
        Self::new()
    }
}

impl GuestPeer {
    pub fn new() -> Self {
        Self {
            session: GuestSession::new(
                "hello".into(),
                ClientIdentity {
                    name: "fake-guest".into(),
                    version: "1".into(),
                },
                ProtocolVersion { major: 1, minor: 0 },
            ),
            decoder: FrameDecoder::default(),
            pending: HashSet::new(),
            next_id: 1,
            closed: false,
            hello_sent: false,
        }
    }

    pub fn hello_frame(&mut self) -> Result<Vec<u8>, ProtocolError> {
        if self.closed {
            return Err(ProtocolError::ConnectionClosed);
        }
        if self.hello_sent {
            return Err(ProtocolError::InvalidMessage);
        }
        self.hello_sent = true;
        encode_json(&self.session.hello_request())
    }

    pub fn list_calendars(&mut self) -> Result<(String, Vec<u8>), ProtocolError> {
        if self.closed {
            return Err(ProtocolError::ConnectionClosed);
        }
        let GuestSessionState::Available(session) = self.session.state() else {
            return Err(ProtocolError::InvalidMessage);
        };
        if !session
            .capabilities
            .iter()
            .any(|capability| capability.as_str() == "calendar.calendars.list")
        {
            return Err(ProtocolError::CapabilityUnavailable);
        }
        if self.pending.len() >= 32 || self.next_id >= 1024 {
            return Err(ProtocolError::ResourceLimit);
        }
        let id = format!("q{}", self.next_id);
        self.next_id += 1;
        let frame = encode_json(&json!({
            "type": "request", "id": id, "method": "calendar.calendars.list", "params": {}
        }))?;
        self.pending.insert(id.clone());
        Ok((id, frame))
    }

    pub fn cancel(&self, id: &str) -> Result<Vec<u8>, ProtocolError> {
        if !self.pending.contains(id) {
            return Err(ProtocolError::InvalidMessage);
        }
        encode_json(&json!({"type": "cancel", "id": id}))
    }

    pub fn receive(&mut self, bytes: &[u8]) -> Result<Vec<PeerMessage>, ProtocolError> {
        if self.closed {
            return Err(ProtocolError::ConnectionClosed);
        }
        let result = if bytes.len() > 65536 {
            Err(ProtocolError::ResourceLimit)
        } else {
            self.receive_frames(bytes)
        };
        if result.is_err() {
            self.close();
        }
        result
    }

    pub fn finish(&mut self) -> Result<(), ProtocolError> {
        let incomplete = self.decoder.buffered_byte_count() != 0;
        self.close();
        if incomplete {
            Err(ProtocolError::TruncatedFrame)
        } else {
            Ok(())
        }
    }

    fn close(&mut self) {
        self.closed = true;
        self.decoder = FrameDecoder::default();
        self.pending.clear();
    }

    fn receive_frames(&mut self, bytes: &[u8]) -> Result<Vec<PeerMessage>, ProtocolError> {
        if !self.hello_sent {
            return Err(ProtocolError::InvalidMessage);
        }
        let mut messages = Vec::new();
        for payload in self.decoder.push(bytes)? {
            let value = decode_json(&payload)?;
            if self.session.state() == &GuestSessionState::AwaitingHandshake {
                match self.session.accept_handshake(&value) {
                    GuestSessionState::Available(session) => {
                        messages.push(PeerMessage::Ready(session.clone()))
                    }
                    GuestSessionState::LinkUnavailable(failure) => {
                        messages.push(PeerMessage::Unavailable(failure.clone()));
                        self.close();
                        break;
                    }
                    GuestSessionState::AwaitingHandshake => {
                        unreachable!("accept_handshake is terminal")
                    }
                }
                continue;
            }
            if value["type"] == "event" {
                let invalidation: Invalidation =
                    serde_json::from_value(value).map_err(|_| ProtocolError::InvalidMessage)?;
                if invalidation.kind != "event" || invalidation.event != "invalidation" {
                    return Err(ProtocolError::InvalidMessage);
                }
                messages.push(PeerMessage::Invalidated(invalidation.service));
                continue;
            }
            let reply: Reply =
                serde_json::from_value(value).map_err(|_| ProtocolError::InvalidMessage)?;
            let id = match &reply {
                Reply::Response { id, .. } | Reply::Error { id, .. } => id,
            };
            if !self.pending.remove(id) {
                return Err(ProtocolError::InvalidMessage);
            }
            messages.push(match reply {
                Reply::Response { id, result } => {
                    if result.calendars.len() > 128
                        || result.calendars.iter().any(|calendar| {
                            calendar.id.is_empty()
                                || calendar.id.len() > 64
                                || calendar.title.is_empty()
                                || calendar.title.len() > 256
                        })
                    {
                        return Err(ProtocolError::InvalidMessage);
                    }
                    PeerMessage::Calendars {
                        id,
                        calendars: result.calendars,
                    }
                }
                Reply::Error { id, error } => {
                    if error.message.is_empty() || error.message.len() > 256 {
                        return Err(ProtocolError::InvalidMessage);
                    }
                    PeerMessage::Failed { id, failure: error }
                }
            });
        }
        Ok(messages)
    }
}

#[derive(Deserialize)]
#[serde(tag = "type")]
enum Reply {
    #[serde(rename = "response")]
    Response { id: String, result: CalendarResult },
    #[serde(rename = "error")]
    Error { id: String, error: RequestFailure },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Invalidation {
    #[serde(rename = "type")]
    kind: String,
    event: String,
    service: MacService,
}

#[derive(Deserialize)]
struct CalendarResult {
    calendars: Vec<Calendar>,
}
