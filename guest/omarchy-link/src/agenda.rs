use crate::{GuestPeer, PeerMessage, decode_json, encode_json};
use serde::Serialize;
use serde_json::json;
use std::collections::HashSet;
use std::fmt;
use std::str::FromStr;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgendaRange {
    Today,
    SevenDays,
}

impl AgendaRange {
    fn day_count(self) -> u8 {
        match self {
            Self::Today => 1,
            Self::SevenDays => 7,
        }
    }
}

impl FromStr for AgendaRange {
    type Err = AgendaError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "today" => Ok(Self::Today),
            "seven-days" => Ok(Self::SevenDays),
            _ => Err(AgendaError::InvalidRange),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaCalendar {
    pub id: String,
    pub title: String,
    pub color: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaEvent {
    pub id: String,
    pub calendar_id: String,
    pub title: String,
    pub date: String,
    pub start_time: Option<String>,
    pub end_time: Option<String>,
    pub all_day: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaWindow {
    pub start_date: String,
    pub day_count: u8,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgendaSnapshot {
    pub source: String,
    pub range: AgendaWindow,
    pub calendars: Vec<AgendaCalendar>,
    pub events: Vec<AgendaEvent>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum AgendaError {
    InvalidDate,
    InvalidRange,
    UnknownCalendar,
    InvalidAdapterData,
}

impl fmt::Display for AgendaError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidDate => "the demo date must use a valid YYYY-MM-DD value",
            Self::InvalidRange => "the demo range must be today or seven-days",
            Self::UnknownCalendar => "the selected invented calendar does not exist",
            Self::InvalidAdapterData => "the invented Calendar adapter returned invalid data",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for AgendaError {}

/// The development broker sees only this bounded Calendar interface. The
/// invented implementation below can be replaced without changing its query
/// and presentation model.
pub trait CalendarHostAdapter {
    fn calendars(&self) -> Vec<AgendaCalendar>;

    fn events(
        &self,
        starting_on: &str,
        day_count: u8,
        calendar_id: Option<&str>,
    ) -> Vec<AgendaEvent>;
}

pub struct DevelopmentAgendaBroker<Adapter> {
    adapter: Adapter,
}

impl<Adapter: CalendarHostAdapter> DevelopmentAgendaBroker<Adapter> {
    pub fn new(adapter: Adapter) -> Self {
        Self { adapter }
    }

    pub fn agenda(
        &self,
        starting_on: &str,
        range: AgendaRange,
        calendar_id: Option<&str>,
    ) -> Result<AgendaSnapshot, AgendaError> {
        let start = CalendarDay::parse(starting_on).ok_or(AgendaError::InvalidDate)?;
        let day_count = range.day_count();
        let end = start
            .adding_days(day_count.into())
            .ok_or(AgendaError::InvalidDate)?;
        let mut guest = ready_guest()?;
        let (calendar_request_id, calendar_request) = guest
            .list_calendars()
            .map_err(|_| AgendaError::InvalidAdapterData)?;
        require_method(&calendar_request, "calendar.calendars.list")?;
        let host_calendars = self.adapter.calendars();
        let host_calendar_ids: HashSet<&str> = host_calendars
            .iter()
            .map(|calendar| calendar.id.as_str())
            .collect();
        if host_calendar_ids.len() != host_calendars.len()
            || host_calendars.iter().any(|calendar| {
                calendar.id.is_empty()
                    || calendar.id.len() > 64
                    || calendar.title.is_empty()
                    || calendar.title.len() > 256
                    || !valid_color(&calendar.color)
            })
        {
            return Err(AgendaError::InvalidAdapterData);
        }
        let calendar_reply = encode_json(&json!({
            "type": "response",
            "id": calendar_request_id,
            "result": {"calendars": host_calendars.iter().map(|calendar| json!({
                "id": calendar.id,
                "title": calendar.title,
            })).collect::<Vec<_>>()}
        }))
        .map_err(|_| AgendaError::InvalidAdapterData)?;
        let calendars = match guest
            .receive(&calendar_reply)
            .map_err(|_| AgendaError::InvalidAdapterData)?
            .as_slice()
        {
            [PeerMessage::Calendars { calendars, .. }] => calendars
                .iter()
                .enumerate()
                .map(|(index, calendar)| AgendaCalendar {
                    id: calendar.id.clone(),
                    title: calendar.title.clone(),
                    color: if index.is_multiple_of(2) {
                        "#7aa2f7".to_owned()
                    } else {
                        "#bb9af7".to_owned()
                    },
                })
                .collect::<Vec<_>>(),
            _ => return Err(AgendaError::InvalidAdapterData),
        };
        let calendar_ids: HashSet<&str> = calendars
            .iter()
            .map(|calendar| calendar.id.as_str())
            .collect();
        if calendar_id.is_some_and(|id| !calendar_ids.contains(id)) {
            return Err(AgendaError::UnknownCalendar);
        }

        let selected = calendar_id
            .map(str::to_owned)
            .into_iter()
            .collect::<Vec<_>>();
        let start_timestamp = format!("{start}T00:00:00Z");
        let end_timestamp = format!("{end}T00:00:00Z");
        let (event_id, event_request) = guest
            .list_events(&start_timestamp, &end_timestamp, &selected)
            .map_err(|_| AgendaError::InvalidAdapterData)?;
        require_method(&event_request, "calendar.events.list")?;
        let host_events = self.adapter.events(starting_on, day_count, calendar_id);
        if host_events.len() > 512
            || host_events.iter().any(|event| {
                let Some(day) = CalendarDay::parse(&event.date) else {
                    return true;
                };
                !calendar_ids.contains(event.calendar_id.as_str())
                    || calendar_id.is_some_and(|id| event.calendar_id != id)
                    || day < start
                    || day >= end
                    || event.id.is_empty()
                    || event.id.len() > 128
                    || event.title.is_empty()
                    || event.title.len() > 512
                    || !valid_event_time(event)
            })
        {
            return Err(AgendaError::InvalidAdapterData);
        }
        let wire_events = host_events
            .iter()
            .map(wire_event)
            .collect::<Result<Vec<_>, _>>()?;
        let event_reply = encode_json(&json!({
            "type": "response",
            "id": event_id,
            "result": {"events": wire_events}
        }))
        .map_err(|_| AgendaError::InvalidAdapterData)?;
        let mut events = match guest
            .receive(&event_reply)
            .map_err(|_| AgendaError::InvalidAdapterData)?
            .as_slice()
        {
            [PeerMessage::Events { events, .. }] => events
                .iter()
                .map(|event| AgendaEvent {
                    id: event.id.clone(),
                    calendar_id: event.calendar_id.clone(),
                    title: event.title.clone(),
                    date: event.starts_at[0..10].to_owned(),
                    start_time: (!event.all_day).then(|| event.starts_at[11..16].to_owned()),
                    end_time: (!event.all_day).then(|| event.ends_at[11..16].to_owned()),
                    all_day: event.all_day,
                })
                .collect::<Vec<_>>(),
            _ => return Err(AgendaError::InvalidAdapterData),
        };
        events.sort_by(|left, right| {
            (&left.date, &left.start_time, &left.id).cmp(&(
                &right.date,
                &right.start_time,
                &right.id,
            ))
        });

        Ok(AgendaSnapshot {
            source: "invented".to_owned(),
            range: AgendaWindow {
                start_date: starting_on.to_owned(),
                day_count,
            },
            calendars,
            events,
        })
    }
}

fn ready_guest() -> Result<GuestPeer, AgendaError> {
    let mut guest = GuestPeer::new();
    let hello = guest
        .hello_frame()
        .map_err(|_| AgendaError::InvalidAdapterData)?;
    require_method(&hello, "session.hello")?;
    let response = encode_json(&json!({
        "type": "response",
        "id": "hello",
        "result": {
            "protocol": {"major": 1, "minor": 0},
            "server": {"name": "invented-calendar-host", "version": "1"},
            "capabilities": ["calendar.calendars.list", "calendar.events.list"]
        }
    }))
    .map_err(|_| AgendaError::InvalidAdapterData)?;
    match guest
        .receive(&response)
        .map_err(|_| AgendaError::InvalidAdapterData)?
        .as_slice()
    {
        [PeerMessage::Ready(_)] => Ok(guest),
        _ => Err(AgendaError::InvalidAdapterData),
    }
}

fn require_method(frame: &[u8], expected: &str) -> Result<(), AgendaError> {
    let payload = frame.get(4..).ok_or(AgendaError::InvalidAdapterData)?;
    let message = decode_json(payload).map_err(|_| AgendaError::InvalidAdapterData)?;
    (message["type"] == "request" && message["method"] == expected)
        .then_some(())
        .ok_or(AgendaError::InvalidAdapterData)
}

fn wire_event(event: &AgendaEvent) -> Result<serde_json::Value, AgendaError> {
    let start = if event.all_day {
        format!("{}T00:00:00Z", event.date)
    } else {
        format!(
            "{}T{}:00Z",
            event.date,
            event
                .start_time
                .as_deref()
                .ok_or(AgendaError::InvalidAdapterData)?
        )
    };
    let end = if event.all_day {
        let day = CalendarDay::parse(&event.date).ok_or(AgendaError::InvalidAdapterData)?;
        format!(
            "{}T00:00:00Z",
            day.adding_days(1).ok_or(AgendaError::InvalidAdapterData)?
        )
    } else {
        format!(
            "{}T{}:00Z",
            event.date,
            event
                .end_time
                .as_deref()
                .ok_or(AgendaError::InvalidAdapterData)?
        )
    };
    Ok(json!({
        "id": event.id,
        "calendarId": event.calendar_id,
        "title": event.title,
        "startsAt": start,
        "endsAt": end,
        "allDay": event.all_day,
    }))
}

fn valid_color(value: &str) -> bool {
    value.len() == 7
        && value.starts_with('#')
        && value[1..].bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn valid_event_time(event: &AgendaEvent) -> bool {
    if event.all_day {
        return event.start_time.is_none() && event.end_time.is_none();
    }
    match (&event.start_time, &event.end_time) {
        (Some(start), Some(end)) => valid_time(start) && valid_time(end) && start < end,
        _ => false,
    }
}

fn valid_time(value: &str) -> bool {
    let bytes = value.as_bytes();
    if bytes.len() != 5
        || bytes[2] != b':'
        || !bytes
            .iter()
            .enumerate()
            .all(|(index, byte)| index == 2 || byte.is_ascii_digit())
    {
        return false;
    }
    let hour = (bytes[0] - b'0') * 10 + bytes[1] - b'0';
    let minute = (bytes[3] - b'0') * 10 + bytes[4] - b'0';
    hour < 24 && minute < 60
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
struct CalendarDay {
    year: u16,
    month: u8,
    day: u8,
}

impl CalendarDay {
    fn parse(value: &str) -> Option<Self> {
        let bytes = value.as_bytes();
        if bytes.len() != 10
            || bytes[4] != b'-'
            || bytes[7] != b'-'
            || !bytes
                .iter()
                .enumerate()
                .all(|(index, byte)| index == 4 || index == 7 || byte.is_ascii_digit())
        {
            return None;
        }
        let year = value[0..4].parse().ok()?;
        let month = value[5..7].parse().ok()?;
        let day = value[8..10].parse().ok()?;
        let result = Self { year, month, day };
        (year > 0 && month > 0 && month <= 12 && day > 0 && day <= result.days_in_month())
            .then_some(result)
    }

    fn adding_days(mut self, count: u16) -> Option<Self> {
        for _ in 0..count {
            if self.day < self.days_in_month() {
                self.day += 1;
            } else if self.month < 12 {
                self.month += 1;
                self.day = 1;
            } else if self.year < 9999 {
                self.year += 1;
                self.month = 1;
                self.day = 1;
            } else {
                return None;
            }
        }
        Some(self)
    }

    fn days_in_month(self) -> u8 {
        match self.month {
            1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
            4 | 6 | 9 | 11 => 30,
            2 if self.year.is_multiple_of(400)
                || (self.year.is_multiple_of(4) && !self.year.is_multiple_of(100)) =>
            {
                29
            }
            2 => 28,
            _ => 0,
        }
    }
}

impl fmt::Display for CalendarDay {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            formatter,
            "{:04}-{:02}-{:02}",
            self.year, self.month, self.day
        )
    }
}

/// Invented data only. Events are generated relative to the requested date so
/// the live Today view remains useful without reading any Mac calendar.
pub struct InventedCalendarHostAdapter;

impl CalendarHostAdapter for InventedCalendarHostAdapter {
    fn calendars(&self) -> Vec<AgendaCalendar> {
        vec![
            AgendaCalendar {
                id: "invented-focus".to_owned(),
                title: "Invented Focus".to_owned(),
                color: "#7aa2f7".to_owned(),
            },
            AgendaCalendar {
                id: "invented-personal".to_owned(),
                title: "Invented Personal".to_owned(),
                color: "#bb9af7".to_owned(),
            },
        ]
    }

    fn events(
        &self,
        starting_on: &str,
        day_count: u8,
        calendar_id: Option<&str>,
    ) -> Vec<AgendaEvent> {
        let start = CalendarDay::parse(starting_on).expect("the broker validates the date");
        let fixtures = [
            (
                0,
                "invented-planning",
                "invented-focus",
                "Project Aurora planning",
                Some("09:00"),
                Some("09:45"),
                false,
            ),
            (
                0,
                "invented-lunch",
                "invented-personal",
                "Lunch with Morgan",
                Some("12:30"),
                Some("13:30"),
                false,
            ),
            (
                1,
                "invented-review",
                "invented-focus",
                "Design review",
                Some("15:00"),
                Some("16:00"),
                false,
            ),
            (
                3,
                "invented-reminder",
                "invented-personal",
                "Dentist reminder",
                Some("08:30"),
                Some("09:00"),
                false,
            ),
            (
                6,
                "invented-wrap",
                "invented-focus",
                "Weekly wrap-up",
                None,
                None,
                true,
            ),
            (
                7,
                "invented-later",
                "invented-focus",
                "Outside the seven-day window",
                Some("10:00"),
                Some("10:30"),
                false,
            ),
        ];
        fixtures
            .into_iter()
            .filter(|(offset, _, event_calendar, ..)| {
                *offset < day_count.into()
                    && calendar_id.is_none_or(|selected| selected == *event_calendar)
            })
            .map(
                |(offset, id, event_calendar, title, start_time, end_time, all_day)| AgendaEvent {
                    id: id.to_owned(),
                    calendar_id: event_calendar.to_owned(),
                    title: title.to_owned(),
                    date: start
                        .adding_days(offset)
                        .expect("a seven-day demo date remains representable")
                        .to_string(),
                    start_time: start_time.map(str::to_owned),
                    end_time: end_time.map(str::to_owned),
                    all_day,
                },
            )
            .collect()
    }
}
