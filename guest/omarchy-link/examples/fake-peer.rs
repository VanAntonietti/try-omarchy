//! Test-only stdio peer for the Swift loopback. All data is invented.
use omarchy_link::{
    Calendar, CalendarEvent, GuestPeer, MacService, PeerMessage, RequestFailureCode,
};
use std::io::{self, Read, Write};

fn main() {
    let mut guest = GuestPeer::new();
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    output.write_all(&guest.hello_frame().unwrap()).unwrap();
    output.flush().unwrap();
    assert!(matches!(
        receive(&mut guest, &mut input, 1).as_slice(),
        [PeerMessage::Ready(_)]
    ));

    let (first, first_frame) = guest.list_calendars().unwrap();
    let (second, second_frame) = guest
        .list_events(
            "2026-09-14T00:00:00Z",
            "2026-09-21T00:00:00Z",
            &["invented-focus".to_owned()],
        )
        .unwrap();
    let (third, third_frame) = guest.list_calendars().unwrap();
    let batch = [
        first_frame,
        second_frame,
        third_frame,
        guest.cancel(&third).unwrap(),
    ]
    .concat();
    output.write_all(&batch).unwrap();
    output.flush().unwrap();
    let messages = receive(&mut guest, &mut input, 4);
    assert!(matches!(&messages[0], PeerMessage::Failed { id, failure }
        if id == &third && failure.code == RequestFailureCode::Cancelled));
    assert_eq!(messages[1], PeerMessage::Invalidated(MacService::Calendar));
    assert_eq!(
        messages[2],
        PeerMessage::Events {
            id: second,
            events: vec![
                CalendarEvent {
                    id: "invented-planning".into(),
                    calendar_id: "invented-focus".into(),
                    title: "Project Aurora planning".into(),
                    starts_at: "2026-09-14T09:00:00Z".into(),
                    ends_at: "2026-09-14T09:45:00Z".into(),
                    all_day: false,
                },
                CalendarEvent {
                    id: "invented-review".into(),
                    calendar_id: "invented-focus".into(),
                    title: "Design review".into(),
                    starts_at: "2026-09-15T15:00:00Z".into(),
                    ends_at: "2026-09-15T16:00:00Z".into(),
                    all_day: false,
                },
                CalendarEvent {
                    id: "invented-wrap".into(),
                    calendar_id: "invented-focus".into(),
                    title: "Weekly wrap-up".into(),
                    starts_at: "2026-09-20T00:00:00Z".into(),
                    ends_at: "2026-09-21T00:00:00Z".into(),
                    all_day: true,
                },
            ],
        }
    );
    assert_eq!(
        messages[3],
        PeerMessage::Calendars {
            id: first,
            calendars: vec![
                Calendar {
                    id: "invented-focus".into(),
                    title: "Invented Focus".into()
                },
                Calendar {
                    id: "invented-personal".into(),
                    title: "Invented Personal".into()
                },
            ],
        }
    );
    let mut trailing = [0; 1];
    assert_eq!(input.read(&mut trailing).unwrap(), 0);
    guest.finish().unwrap();
}

fn receive(guest: &mut GuestPeer, input: &mut impl Read, count: usize) -> Vec<PeerMessage> {
    let mut messages = Vec::new();
    let mut buffer = [0; 16384];
    while messages.len() < count {
        let size = input.read(&mut buffer).unwrap();
        assert_ne!(size, 0, "host closed before all replies arrived");
        messages.extend(guest.receive(&buffer[..size]).unwrap());
    }
    assert_eq!(messages.len(), count);
    messages
}
