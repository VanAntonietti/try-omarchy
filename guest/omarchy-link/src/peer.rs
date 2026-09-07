use crate::{
    ClientIdentity, FrameDecoder, GuestSession, GuestSessionState, NegotiatedSession,
    ProtocolError, ProtocolVersion, SessionFailure, decode_json, encode_json,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Calendar {
    pub id: String,
    pub title: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarEvent {
    pub id: String,
    pub calendar_id: String,
    pub title: String,
    pub starts_at: String,
    pub ends_at: String,
    pub all_day: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProposalCalendar {
    pub id: String,
    pub title: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CalendarMutationProposal {
    pub id: String,
    pub service: String,
    pub operation: String,
    pub title: String,
    pub starts_at: String,
    pub ends_at: String,
    pub calendar: ProposalCalendar,
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

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CalendarCreateOutcome {
    Succeeded,
    Failed,
    Uncertain,
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
    Events {
        id: String,
        events: Vec<CalendarEvent>,
    },
    MutationProposed {
        id: String,
        proposal: CalendarMutationProposal,
    },
    MutationPerformed {
        id: String,
        outcome: CalendarCreateOutcome,
    },
    Failed {
        id: String,
        failure: RequestFailure,
    },
}

#[derive(Clone, Copy)]
enum PendingQuery {
    Calendars,
    Events,
    CalendarCreateProposal,
    CalendarCreatePerform,
}

/// A fake-data protocol peer, not a daemon or a connection to a Mac Service.
pub struct GuestPeer {
    session: GuestSession,
    decoder: FrameDecoder,
    pending: HashMap<String, PendingQuery>,
    next_id: u32,
    request_monotonic_ids: bool,
    request_id_limit: u32,
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
            pending: HashMap::new(),
            next_id: 1,
            request_monotonic_ids: false,
            request_id_limit: 1024,
            closed: false,
            hello_sent: false,
        }
    }

    /// Creates the peer for a launcher-validated Workspace and unique handshake attempt.
    pub fn for_workspace(identity: String, attempt: String) -> Self {
        let mut peer = Self::new();
        peer.session = GuestSession::new(
            format!("hello-{attempt}"),
            ClientIdentity {
                name: "omarchy-link".into(),
                version: env!("CARGO_PKG_VERSION").into(),
            },
            ProtocolVersion { major: 1, minor: 0 },
        )
        .with_workspace_identity(identity);
        peer.request_monotonic_ids = true;
        peer
    }

    pub fn hello_frame(&mut self) -> Result<Vec<u8>, ProtocolError> {
        if self.closed {
            return Err(ProtocolError::ConnectionClosed);
        }
        if self.hello_sent {
            return Err(ProtocolError::InvalidMessage);
        }
        self.hello_sent = true;
        let mut hello = self.session.hello_request();
        if self.request_monotonic_ids {
            hello["params"]["requestIdPolicy"] = json!("monotonic-q");
        }
        encode_json(&hello)
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
        if self.pending.len() >= 32 || self.next_id >= self.request_id_limit {
            return Err(ProtocolError::ResourceLimit);
        }
        let id = format!("q{}", self.next_id);
        self.next_id += 1;
        let frame = encode_json(&json!({
            "type": "request", "id": id, "method": "calendar.calendars.list", "params": {}
        }))?;
        self.pending.insert(id.clone(), PendingQuery::Calendars);
        Ok((id, frame))
    }

    pub fn list_events(
        &mut self,
        start: &str,
        end: &str,
        calendar_ids: &[String],
    ) -> Result<(String, Vec<u8>), ProtocolError> {
        if self.closed {
            return Err(ProtocolError::ConnectionClosed);
        }
        let GuestSessionState::Available(session) = self.session.state() else {
            return Err(ProtocolError::InvalidMessage);
        };
        if !session
            .capabilities
            .iter()
            .any(|capability| capability.as_str() == "calendar.events.list")
        {
            return Err(ProtocolError::CapabilityUnavailable);
        }
        let (Some(start_seconds), Some(end_seconds)) =
            (timestamp_seconds(start), timestamp_seconds(end))
        else {
            return Err(ProtocolError::InvalidMessage);
        };
        if end_seconds <= start_seconds
            || end_seconds - start_seconds > 8 * 24 * 60 * 60
            || calendar_ids.len() > 128
            || calendar_ids.iter().any(|id| {
                id.is_empty()
                    || id.len() > 64
                    || calendar_ids.iter().filter(|other| *other == id).count() != 1
            })
        {
            return Err(ProtocolError::InvalidMessage);
        }
        if self.pending.len() >= 32 || self.next_id >= self.request_id_limit {
            return Err(ProtocolError::ResourceLimit);
        }
        let id = format!("q{}", self.next_id);
        self.next_id += 1;
        let frame = encode_json(&json!({
            "type": "request",
            "id": id,
            "method": "calendar.events.list",
            "params": {"start": start, "end": end, "calendarIds": calendar_ids}
        }))?;
        self.pending.insert(id.clone(), PendingQuery::Events);
        Ok((id, frame))
    }

    pub fn propose_calendar_event(
        &mut self,
        title: &str,
        starts_at: &str,
        ends_at: &str,
        calendar_id: &str,
    ) -> Result<(String, Vec<u8>), ProtocolError> {
        if self.closed {
            return Err(ProtocolError::ConnectionClosed);
        }
        let GuestSessionState::Available(session) = self.session.state() else {
            return Err(ProtocolError::InvalidMessage);
        };
        if !session
            .capabilities
            .iter()
            .any(|capability| capability.as_str() == "calendar.events.create.propose")
        {
            return Err(ProtocolError::CapabilityUnavailable);
        }
        let (Some(start_seconds), Some(end_seconds)) =
            (timestamp_seconds(starts_at), timestamp_seconds(ends_at))
        else {
            return Err(ProtocolError::InvalidMessage);
        };
        if title.is_empty()
            || title.len() > 512
            || end_seconds <= start_seconds
            || calendar_id.is_empty()
            || calendar_id.len() > 64
        {
            return Err(ProtocolError::InvalidMessage);
        }
        if self.pending.len() >= 32 || self.next_id >= self.request_id_limit {
            return Err(ProtocolError::ResourceLimit);
        }
        let id = format!("q{}", self.next_id);
        self.next_id += 1;
        let frame = encode_json(&json!({
            "type": "request",
            "id": id,
            "method": "calendar.events.create.propose",
            "params": {
                "title": title,
                "startsAt": starts_at,
                "endsAt": ends_at,
                "calendarId": calendar_id
            }
        }))?;
        self.pending
            .insert(id.clone(), PendingQuery::CalendarCreateProposal);
        Ok((id, frame))
    }

    pub fn perform_calendar_event(
        &mut self,
        proposal_id: &str,
    ) -> Result<(String, Vec<u8>), ProtocolError> {
        if self.closed {
            return Err(ProtocolError::ConnectionClosed);
        }
        let GuestSessionState::Available(session) = self.session.state() else {
            return Err(ProtocolError::InvalidMessage);
        };
        if !session
            .capabilities
            .iter()
            .any(|c| c.as_str() == "calendar.events.create.perform")
        {
            return Err(ProtocolError::CapabilityUnavailable);
        }
        if proposal_id.is_empty() || proposal_id.len() > 128 {
            return Err(ProtocolError::InvalidMessage);
        }
        if self.pending.len() >= 32 || self.next_id >= self.request_id_limit {
            return Err(ProtocolError::ResourceLimit);
        }
        let id = format!("q{}", self.next_id);
        self.next_id += 1;
        let frame = encode_json(&json!({
            "type":"request", "id":id, "method":"calendar.events.create.perform",
            "params":{"proposalId":proposal_id}
        }))?;
        self.pending
            .insert(id.clone(), PendingQuery::CalendarCreatePerform);
        Ok((id, frame))
    }

    pub fn cancel(&self, id: &str) -> Result<Vec<u8>, ProtocolError> {
        if !self.pending.contains_key(id) {
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
                        if self.request_monotonic_ids
                            && value["result"]["requestIdPolicy"] == "monotonic-q"
                        {
                            self.request_id_limit = u32::MAX;
                        }
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
            let Some(pending) = self.pending.remove(id) else {
                return Err(ProtocolError::InvalidMessage);
            };
            messages.push(match reply {
                Reply::Response { id, result } => match pending {
                    PendingQuery::Calendars => {
                        let result: CalendarResult = serde_json::from_value(result)
                            .map_err(|_| ProtocolError::InvalidMessage)?;
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
                    PendingQuery::Events => {
                        let result: EventResult = serde_json::from_value(result)
                            .map_err(|_| ProtocolError::InvalidMessage)?;
                        if result.events.len() > 512
                            || result.events.iter().any(|event| {
                                event.id.is_empty()
                                    || event.id.len() > 128
                                    || event.calendar_id.is_empty()
                                    || event.calendar_id.len() > 64
                                    || event.title.is_empty()
                                    || event.title.len() > 512
                                    || !valid_timestamp(&event.starts_at)
                                    || !valid_timestamp(&event.ends_at)
                                    || event.starts_at >= event.ends_at
                            })
                        {
                            return Err(ProtocolError::InvalidMessage);
                        }
                        PeerMessage::Events {
                            id,
                            events: result.events,
                        }
                    }
                    PendingQuery::CalendarCreatePerform => {
                        let outcome = serde_json::from_value(result["outcome"].clone())
                            .map_err(|_| ProtocolError::InvalidMessage)?;
                        PeerMessage::MutationPerformed { id, outcome }
                    }
                    PendingQuery::CalendarCreateProposal => {
                        let result: MutationProposalResult = serde_json::from_value(result)
                            .map_err(|_| ProtocolError::InvalidMessage)?;
                        let proposal = result.proposal;
                        if proposal.id.is_empty()
                            || proposal.id.len() > 128
                            || proposal.service != "calendar"
                            || proposal.operation != "event.create"
                            || proposal.title.is_empty()
                            || proposal.title.len() > 512
                            || proposal.calendar.id.is_empty()
                            || proposal.calendar.id.len() > 64
                            || proposal.calendar.title.is_empty()
                            || proposal.calendar.title.len() > 256
                            || !valid_timestamp(&proposal.starts_at)
                            || !valid_timestamp(&proposal.ends_at)
                            || proposal.starts_at >= proposal.ends_at
                        {
                            return Err(ProtocolError::InvalidMessage);
                        }
                        PeerMessage::MutationProposed { id, proposal }
                    }
                },
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
    Response { id: String, result: Value },
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

#[derive(Deserialize)]
struct EventResult {
    events: Vec<CalendarEvent>,
}

#[derive(Deserialize)]
struct MutationProposalResult {
    proposal: CalendarMutationProposal,
}

fn valid_timestamp(value: &str) -> bool {
    timestamp_seconds(value).is_some()
}

pub(crate) fn timestamp_seconds(value: &str) -> Option<u64> {
    let bytes = value.as_bytes();
    if bytes.len() != 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes[19] != b'Z'
        || !bytes.iter().enumerate().all(|(index, byte)| {
            matches!(index, 4 | 7 | 10 | 13 | 16 | 19) || byte.is_ascii_digit()
        })
    {
        return None;
    }
    let year = value[0..4].parse::<u64>().ok()?;
    let month = value[5..7].parse::<u8>().ok()?;
    let day = value[8..10].parse::<u64>().ok()?;
    let hour = value[11..13].parse::<u64>().ok()?;
    let minute = value[14..16].parse::<u64>().ok()?;
    let second = value[17..19].parse::<u64>().ok()?;
    if year == 0 || hour >= 24 || minute >= 60 || second >= 60 {
        return None;
    }
    let leap = year.is_multiple_of(400) || (year.is_multiple_of(4) && !year.is_multiple_of(100));
    let days_in_month = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return None,
    };
    if day == 0 || day > days_in_month {
        return None;
    }
    let days_before_month = [0_u64, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
    let previous_year = year - 1;
    let days_before_year =
        365 * previous_year + previous_year / 4 - previous_year / 100 + previous_year / 400;
    let leap_day = u64::from(leap && month > 2);
    let elapsed_days =
        days_before_year + days_before_month[usize::from(month - 1)] + leap_day + day - 1;
    Some(elapsed_days * 86_400 + hour * 3_600 + minute * 60 + second)
}
