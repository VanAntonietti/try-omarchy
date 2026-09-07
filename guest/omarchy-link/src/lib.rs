mod agenda;
mod channel;
mod mutation;
mod peer;
mod session;

pub use agenda::{
    AgendaCalendar, AgendaError, AgendaEvent, AgendaRange, AgendaSnapshot, AgendaWindow,
    CalendarHostAdapter, DevelopmentAgendaBroker, InventedCalendarHostAdapter,
};
pub use mutation::{
    CalendarCreateRequest, DevelopmentMutationBroker, MutationError, ReviewDecision,
    ReviewFailureCode, ReviewInterlock, ReviewPresentation, ReviewResult, ReviewStatus,
    ReviewUiState,
};
pub use peer::{
    Calendar, CalendarEvent, CalendarMutationProposal, GuestPeer, MacService, PeerMessage,
    ProposalCalendar, RequestFailure, RequestFailureCode,
};

pub use channel::{
    CHANNEL_DEVICE, ChannelError, channel_status_value, negotiate_link_session,
    workspace_identity_from_command_line,
};
pub use session::{
    CapabilityName, ClientIdentity, GuestSession, GuestSessionState, NegotiatedSession,
    ProtocolVersion, SessionFailure, SessionFailureCode,
};

use serde_json::Value;
use std::fmt;

pub const HEADER_BYTES: usize = 4;
pub const MAXIMUM_PAYLOAD_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Eq, PartialEq)]
pub enum ProtocolError {
    EmptyFrame,
    FrameTooLarge(usize),
    InvalidJsonObject,
    InvalidMessage,
    ResourceLimit,
    ConnectionClosed,
    TruncatedFrame,
    CapabilityUnavailable,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::CapabilityUnavailable => write!(formatter, "The Capability is not available"),
            Self::ResourceLimit => write!(formatter, "Omarchy Link peer resource limit exceeded"),
            Self::ConnectionClosed => write!(formatter, "Omarchy Link peer is closed"),
            Self::TruncatedFrame => {
                write!(formatter, "Omarchy Link ended with an incomplete frame")
            }
            Self::EmptyFrame => write!(formatter, "Omarchy Link frames cannot be empty"),
            Self::FrameTooLarge(size) => {
                write!(formatter, "Omarchy Link frame is too large ({size} bytes)")
            }
            Self::InvalidMessage => write!(
                formatter,
                "Omarchy Link message does not match the protocol schema"
            ),
            Self::InvalidJsonObject => {
                write!(
                    formatter,
                    "Omarchy Link payload must be one valid JSON object"
                )
            }
        }
    }
}

impl std::error::Error for ProtocolError {}

pub fn encode_json(value: &Value) -> Result<Vec<u8>, ProtocolError> {
    if !value.is_object() {
        return Err(ProtocolError::InvalidJsonObject);
    }
    let payload = serde_json::to_vec(value).map_err(|_| ProtocolError::InvalidJsonObject)?;
    encode_payload(&payload)
}

pub fn decode_json(payload: &[u8]) -> Result<Value, ProtocolError> {
    validate_payload_size(payload.len())?;
    let value: Value =
        serde_json::from_slice(payload).map_err(|_| ProtocolError::InvalidJsonObject)?;
    if !value.is_object() {
        return Err(ProtocolError::InvalidJsonObject);
    }
    Ok(value)
}

pub fn encode_payload(payload: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    validate_payload_size(payload.len())?;
    decode_json(payload)?;

    let mut frame = Vec::with_capacity(HEADER_BYTES + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

fn validate_payload_size(size: usize) -> Result<(), ProtocolError> {
    if size == 0 {
        return Err(ProtocolError::EmptyFrame);
    }
    if size > MAXIMUM_PAYLOAD_BYTES {
        return Err(ProtocolError::FrameTooLarge(size));
    }
    Ok(())
}

#[derive(Default)]
pub struct FrameDecoder {
    buffer: Vec<u8>,
}

impl FrameDecoder {
    pub fn buffered_byte_count(&self) -> usize {
        self.buffer.len()
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<Vec<u8>>, ProtocolError> {
        self.buffer.extend_from_slice(bytes);
        let mut payloads = Vec::new();

        loop {
            if self.buffer.len() < HEADER_BYTES {
                break;
            }
            let length = u32::from_be_bytes(
                self.buffer[..HEADER_BYTES]
                    .try_into()
                    .expect("a four-byte slice was checked above"),
            ) as usize;
            validate_payload_size(length)?;
            let frame_size = HEADER_BYTES + length;
            if self.buffer.len() < frame_size {
                break;
            }

            let payload = self.buffer[HEADER_BYTES..frame_size].to_vec();
            decode_json(&payload)?;
            self.buffer.drain(..frame_size);
            payloads.push(payload);
        }

        Ok(payloads)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_empty_oversized_scalar_and_malformed_payloads() {
        assert_eq!(encode_payload(&[]), Err(ProtocolError::EmptyFrame));
        assert_eq!(
            encode_payload(&vec![0; MAXIMUM_PAYLOAD_BYTES + 1]),
            Err(ProtocolError::FrameTooLarge(MAXIMUM_PAYLOAD_BYTES + 1))
        );
        for payload in [b"[]".as_slice(), b"true".as_slice(), b"not json".as_slice()] {
            assert_eq!(
                encode_payload(payload),
                Err(ProtocolError::InvalidJsonObject)
            );
        }

        let mut empty_decoder = FrameDecoder::default();
        assert_eq!(
            empty_decoder.push(&0_u32.to_be_bytes()),
            Err(ProtocolError::EmptyFrame)
        );

        let mut oversized_decoder = FrameDecoder::default();
        let size = (MAXIMUM_PAYLOAD_BYTES + 1) as u32;
        assert_eq!(
            oversized_decoder.push(&size.to_be_bytes()),
            Err(ProtocolError::FrameTooLarge(MAXIMUM_PAYLOAD_BYTES + 1))
        );
    }
}
