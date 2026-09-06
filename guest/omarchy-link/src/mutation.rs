use crate::{
    CalendarHostAdapter, CalendarMutationProposal, GuestPeer, PeerMessage, ProposalCalendar,
    encode_json,
};
use serde::Serialize;
use serde_json::json;
use std::fmt;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CalendarCreateRequest {
    pub title: String,
    pub starts_at: String,
    pub ends_at: String,
    pub calendar_id: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MutationError {
    InvalidRequest,
    UnknownCalendar,
    InvalidAdapterData,
    Protocol,
}

impl fmt::Display for MutationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidRequest => "the invented Calendar create request is invalid",
            Self::UnknownCalendar => "the selected invented calendar does not exist",
            Self::InvalidAdapterData => "the invented Calendar adapter returned invalid data",
            Self::Protocol => "the invented Calendar proposal exchange failed",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for MutationError {}

impl CalendarMutationProposal {
    pub fn review_text(&self) -> String {
        format!(
            "Calendar Mutation Proposal\nTitle: {}\nStart: {}\nEnd: {}\nCalendar: {} ({})\n",
            self.title, self.starts_at, self.ends_at, self.calendar.title, self.calendar.id
        )
    }
}

pub struct DevelopmentMutationBroker<Adapter> {
    adapter: Adapter,
    next_proposal_id: u32,
}

impl<Adapter: CalendarHostAdapter> DevelopmentMutationBroker<Adapter> {
    pub fn new(adapter: Adapter) -> Self {
        Self {
            adapter,
            next_proposal_id: 1,
        }
    }

    pub fn propose(
        &mut self,
        request: &CalendarCreateRequest,
    ) -> Result<CalendarMutationProposal, MutationError> {
        let title = request.title.trim();
        if title.is_empty()
            || title.len() > 512
            || request.calendar_id.is_empty()
            || request.calendar_id.len() > 64
        {
            return Err(MutationError::InvalidRequest);
        }
        let (Some(start), Some(end)) = (
            timestamp_seconds(&request.starts_at),
            timestamp_seconds(&request.ends_at),
        ) else {
            return Err(MutationError::InvalidRequest);
        };
        if start >= end {
            return Err(MutationError::InvalidRequest);
        }

        let calendars = self.adapter.calendars();
        if calendars.len() > 128
            || calendars.iter().any(|calendar| {
                calendar.id.is_empty()
                    || calendar.id.len() > 64
                    || calendar.title.is_empty()
                    || calendar.title.len() > 256
            })
        {
            return Err(MutationError::InvalidAdapterData);
        }
        let calendar = calendars
            .iter()
            .find(|calendar| calendar.id == request.calendar_id)
            .ok_or(MutationError::UnknownCalendar)?;
        let proposal = CalendarMutationProposal {
            id: format!("invented-calendar-proposal-{}", self.next_proposal_id),
            service: "calendar".to_owned(),
            operation: "event.create".to_owned(),
            title: title.to_owned(),
            starts_at: request.starts_at.clone(),
            ends_at: request.ends_at.clone(),
            calendar: ProposalCalendar {
                id: calendar.id.clone(),
                title: calendar.title.clone(),
            },
        };
        self.next_proposal_id += 1;

        let mut guest = ready_guest()?;
        let (request_id, _) = guest
            .propose_calendar_event(
                &request.title,
                &request.starts_at,
                &request.ends_at,
                &request.calendar_id,
            )
            .map_err(|_| MutationError::Protocol)?;
        let reply = encode_json(&json!({
            "type": "response",
            "id": request_id,
            "result": {"proposal": proposal}
        }))
        .map_err(|_| MutationError::Protocol)?;
        match guest
            .receive(&reply)
            .map_err(|_| MutationError::Protocol)?
            .as_slice()
        {
            [PeerMessage::MutationProposed { proposal, .. }] => Ok(proposal.clone()),
            _ => Err(MutationError::Protocol),
        }
    }
}

fn ready_guest() -> Result<GuestPeer, MutationError> {
    let mut guest = GuestPeer::new();
    guest.hello_frame().map_err(|_| MutationError::Protocol)?;
    let response = encode_json(&json!({
        "type": "response",
        "id": "hello",
        "result": {
            "protocol": {"major": 1, "minor": 0},
            "server": {"name": "invented-calendar-host", "version": "1"},
            "capabilities": ["calendar.events.create.propose"]
        }
    }))
    .map_err(|_| MutationError::Protocol)?;
    match guest
        .receive(&response)
        .map_err(|_| MutationError::Protocol)?
        .as_slice()
    {
        [PeerMessage::Ready(_)] => Ok(guest),
        _ => Err(MutationError::Protocol),
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReviewUiState {
    Available,
    Locked,
    Unavailable,
    Headless,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReviewDecision {
    Approve,
    Reject,
    Dismiss,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewStatus {
    Approved,
    Rejected,
    Dismissed,
    Blocked,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
pub enum ReviewFailureCode {
    #[serde(rename = "review.session_locked")]
    SessionLocked,
    #[serde(rename = "review.ui_unavailable")]
    UiUnavailable,
    #[serde(rename = "review.headless")]
    Headless,
    #[serde(rename = "review.not_presented")]
    NotPresented,
    #[serde(rename = "review.already_resolved")]
    AlreadyResolved,
}

impl ReviewFailureCode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::SessionLocked => "review.session_locked",
            Self::UiUnavailable => "review.ui_unavailable",
            Self::Headless => "review.headless",
            Self::NotPresented => "review.not_presented",
            Self::AlreadyResolved => "review.already_resolved",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReviewResult {
    pub status: ReviewStatus,
    pub code: Option<ReviewFailureCode>,
    pub proposal: Option<CalendarMutationProposal>,
    pub performed: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ReviewPresentation {
    Proposal(CalendarMutationProposal),
    Blocked(ReviewResult),
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ReviewState {
    Pending,
    Presented,
    Resolved,
}

pub struct ReviewInterlock {
    proposal: CalendarMutationProposal,
    state: ReviewState,
}

impl ReviewInterlock {
    pub fn new(proposal: CalendarMutationProposal) -> Self {
        Self {
            proposal,
            state: ReviewState::Pending,
        }
    }

    pub fn present(&mut self, ui_state: ReviewUiState) -> ReviewPresentation {
        if self.state != ReviewState::Pending {
            return ReviewPresentation::Blocked(self.blocked(ReviewFailureCode::AlreadyResolved));
        }
        let failure = match ui_state {
            ReviewUiState::Available => {
                self.state = ReviewState::Presented;
                return ReviewPresentation::Proposal(self.proposal.clone());
            }
            ReviewUiState::Locked => ReviewFailureCode::SessionLocked,
            ReviewUiState::Unavailable => ReviewFailureCode::UiUnavailable,
            ReviewUiState::Headless => ReviewFailureCode::Headless,
        };
        self.state = ReviewState::Resolved;
        ReviewPresentation::Blocked(self.blocked(failure))
    }

    pub fn resolve(&mut self, decision: ReviewDecision, ui_state: ReviewUiState) -> ReviewResult {
        if self.state == ReviewState::Resolved {
            return self.blocked(ReviewFailureCode::AlreadyResolved);
        }
        if self.state != ReviewState::Presented {
            self.state = ReviewState::Resolved;
            return self.blocked(ReviewFailureCode::NotPresented);
        }
        let failure = match ui_state {
            ReviewUiState::Available => None,
            ReviewUiState::Locked => Some(ReviewFailureCode::SessionLocked),
            ReviewUiState::Unavailable => Some(ReviewFailureCode::UiUnavailable),
            ReviewUiState::Headless => Some(ReviewFailureCode::Headless),
        };
        self.state = ReviewState::Resolved;
        if let Some(failure) = failure {
            return self.blocked(failure);
        }
        ReviewResult {
            status: match decision {
                ReviewDecision::Approve => ReviewStatus::Approved,
                ReviewDecision::Reject => ReviewStatus::Rejected,
                ReviewDecision::Dismiss => ReviewStatus::Dismissed,
            },
            code: None,
            proposal: Some(self.proposal.clone()),
            performed: false,
        }
    }

    fn blocked(&self, code: ReviewFailureCode) -> ReviewResult {
        ReviewResult {
            status: ReviewStatus::Blocked,
            code: Some(code),
            proposal: None,
            performed: false,
        }
    }
}

fn timestamp_seconds(value: &str) -> Option<u64> {
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
