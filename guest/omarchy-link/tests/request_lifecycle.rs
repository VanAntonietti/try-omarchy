use omarchy_link::{
    Calendar, CalendarEvent, GuestPeer, PeerMessage, RequestFailureCode, encode_json,
};
use serde_json::json;

#[test]
fn cancellation_is_not_approval_and_waits_for_the_correlated_terminal_reply() {
    let mut guest = ready_guest();
    let (id, _) = guest.list_calendars().unwrap();
    let cancel = guest.cancel(&id).unwrap();
    assert_eq!(
        omarchy_link::decode_json(&cancel[4..]).unwrap(),
        json!({"type": "cancel", "id": id})
    );
    let cancelled = guest
        .receive(
            &encode_json(&json!({
                "type": "error", "id": id,
                "error": {"code": "request.cancelled", "message": "The request was cancelled"}
            }))
            .unwrap(),
        )
        .unwrap();
    assert!(
        matches!(&cancelled[0], PeerMessage::Failed { id: reply_id, failure }
        if reply_id == &id && failure.code == RequestFailureCode::Cancelled)
    );
    assert!(guest.cancel(&id).is_err());

    let (id, _) = guest.list_calendars().unwrap();
    guest.cancel(&id).unwrap();
    // Completion may already be in flight when cancellation reaches the host.
    let completed = guest
        .receive(
            &encode_json(&json!({
                "type": "response", "id": id, "result": {"calendars": []}
            }))
            .unwrap(),
        )
        .unwrap();
    assert_eq!(
        completed,
        vec![PeerMessage::Calendars {
            id,
            calendars: vec![]
        }]
    );
}

#[test]
fn invalidations_are_typed_content_free_and_do_not_settle_queries() {
    let mut guest = ready_guest();
    let (id, _) = guest.list_calendars().unwrap();
    for (service, expected) in [
        ("calendar", omarchy_link::MacService::Calendar),
        ("messages", omarchy_link::MacService::Messages),
        ("notes", omarchy_link::MacService::Notes),
    ] {
        assert_eq!(
            guest
                .receive(
                    &encode_json(&json!({
                        "type": "event", "event": "invalidation", "service": service
                    }))
                    .unwrap()
                )
                .unwrap(),
            vec![PeerMessage::Invalidated(expected)]
        );
    }
    assert!(guest.cancel(&id).is_ok());
    for invalid in [
        json!({"type": "event", "event": "invalidation", "service": "calendar", "title": "private"}),
        json!({"type": "event", "event": "invalidation", "service": "files"}),
        json!({"type": "event", "event": "invalidation", "service": "calendar", "id": id}),
    ] {
        assert!(
            ready_guest()
                .receive(&encode_json(&invalid).unwrap())
                .is_err()
        );
    }
}

#[test]
fn invalid_frames_schemas_and_uncorrelated_replies_close_the_peer() {
    use omarchy_link::ProtocolError;
    let cases = [
        (vec![0, 0, 0, 0], ProtocolError::EmptyFrame),
        (vec![0, 64, 0, 1], ProtocolError::FrameTooLarge(4 * 1024 * 1024 + 1)),
        (vec![0, 0, 0, 1, b'{'], ProtocolError::InvalidJsonObject),
        (vec![0; 65537], ProtocolError::ResourceLimit),
        (encode_json(&json!({"type": "error", "id": "q1", "error": {"code": "", "message": "invalid code"}})).unwrap(), ProtocolError::InvalidMessage),
        (encode_json(&json!({})).unwrap(), ProtocolError::InvalidMessage),
        (encode_json(&json!({"type": "response", "id": "unknown", "result": {"calendars": []}})).unwrap(), ProtocolError::InvalidMessage),
        (encode_json(&json!({"type": "response", "id": "q1", "result": {"calendars": "wrong"}})).unwrap(), ProtocolError::InvalidMessage),
        (encode_json(&json!({"type": "response", "id": "q1", "result": {"calendars": [{"id": "", "title": "bad"}]}})).unwrap(), ProtocolError::InvalidMessage),
        (encode_json(&json!({"type": "error", "id": "q1", "error": {"code": "request.busy", "message": ""}})).unwrap(), ProtocolError::InvalidMessage),
    ];
    for (bytes, failure) in cases {
        let mut guest = ready_guest();
        guest.list_calendars().unwrap();
        assert_eq!(guest.receive(&bytes), Err(failure));
        assert_eq!(guest.receive(&[]), Err(ProtocolError::ConnectionClosed));
        assert_eq!(guest.list_calendars(), Err(ProtocolError::ConnectionClosed));
        assert!(guest.cancel("q1").is_err());
    }
    let mut guest = ready_guest();
    guest.receive(&[0, 0, 0, 5, b'{']).unwrap();
    assert_eq!(guest.finish(), Err(ProtocolError::TruncatedFrame));

    let mut guest = ready_guest();
    guest.list_calendars().unwrap();
    let reply =
        encode_json(&json!({"type": "response", "id": "q1", "result": {"calendars": []}})).unwrap();
    guest.receive(&reply).unwrap();
    assert_eq!(guest.receive(&reply), Err(ProtocolError::InvalidMessage));
}

#[test]
fn queries_require_negotiation_and_have_bounded_in_flight_and_lifetime_ids() {
    use omarchy_link::ProtocolError;
    let mut guest = GuestPeer::new();
    assert_eq!(guest.list_calendars(), Err(ProtocolError::InvalidMessage));
    guest.hello_frame().unwrap();
    assert!(guest.hello_frame().is_err());
    guest
        .receive(
            &encode_json(&json!({
                "type": "response", "id": "hello", "result": {
                    "protocol": {"major": 1, "minor": 0},
                    "server": {"name": "fake", "version": "1"}, "capabilities": []
                }
            }))
            .unwrap(),
        )
        .unwrap();
    assert_eq!(
        guest.list_calendars(),
        Err(ProtocolError::CapabilityUnavailable)
    );

    let mut guest = ready_guest();
    for _ in 0..32 {
        guest.list_calendars().unwrap();
    }
    assert_eq!(guest.list_calendars(), Err(ProtocolError::ResourceLimit));
    guest
        .receive(
            &encode_json(&json!({"type": "response", "id": "q1", "result": {"calendars": []}}))
                .unwrap(),
        )
        .unwrap();
    for _ in 33..=1023 {
        let (id, _) = guest.list_calendars().unwrap();
        guest
            .receive(
                &encode_json(&json!({"type": "response", "id": id, "result": {"calendars": []}}))
                    .unwrap(),
            )
            .unwrap();
    }
    assert_eq!(guest.list_calendars(), Err(ProtocolError::ResourceLimit));
}

#[test]
fn a_failed_handshake_preserves_the_typed_link_only_failure() {
    let mut guest = GuestPeer::new();
    guest.hello_frame().unwrap();
    let messages = guest
        .receive(
            &encode_json(&json!({
                "type": "error", "id": "hello",
                "error": {"code": "session.unsupported_protocol", "message": "Unsupported protocol"}
            }))
            .unwrap(),
        )
        .unwrap();
    assert!(matches!(&messages[0], PeerMessage::Unavailable(failure)
        if failure.code.as_str() == "session.unsupported_protocol"));
    assert_eq!(
        guest.list_calendars(),
        Err(omarchy_link::ProtocolError::ConnectionClosed)
    );
}

#[test]
fn fragmented_maximum_size_responses_and_additive_fields_remain_compatible() {
    let mut guest = ready_guest();
    guest.list_calendars().unwrap();
    let prefix = r#"{"type":"response","id":"q1","result":{"calendars":[],"future":""#;
    let suffix = "\"}}";
    let payload = format!(
        "{prefix}{}{suffix}",
        "x".repeat(4 * 1024 * 1024 - prefix.len() - suffix.len())
    );
    let mut frame = vec![0, 64, 0, 0];
    frame.extend_from_slice(payload.as_bytes());
    let mut messages = vec![];
    for chunk in frame.chunks(65536) {
        messages.extend(guest.receive(chunk).unwrap());
    }
    assert_eq!(
        messages,
        vec![PeerMessage::Calendars {
            id: "q1".into(),
            calendars: vec![]
        }]
    );
    let (id, _) = guest.list_calendars().unwrap();
    let future = guest
        .receive(
            &encode_json(&json!({
                "type": "error", "id": id, "future": true,
                "error": {"code": "future.failure", "message": "Future failure", "future": true}
            }))
            .unwrap(),
        )
        .unwrap();
    assert!(matches!(&future[0], PeerMessage::Failed { failure, .. }
        if failure.code == RequestFailureCode::Unknown));
}

fn ready_guest() -> GuestPeer {
    let mut guest = GuestPeer::new();
    let hello = guest.hello_frame().unwrap();
    assert!(!hello.is_empty());
    let ready = guest
        .receive(
            &encode_json(&json!({
                "type": "response", "id": "hello", "result": {
                    "protocol": {"major": 1, "minor": 0},
                    "server": {"name": "fake-host", "version": "1"},
                    "capabilities": ["calendar.calendars.list", "calendar.events.list"]
                }
            }))
            .unwrap(),
        )
        .unwrap();
    assert!(matches!(ready.as_slice(), [PeerMessage::Ready(_)]));
    guest
}

#[test]
fn agenda_queries_are_typed_and_filtered_by_calendar_identifiers() {
    let mut guest = ready_guest();
    assert_eq!(
        guest.list_events("2026-09-14T00:00:00Z", "2026-09-23T00:00:00Z", &[],),
        Err(omarchy_link::ProtocolError::InvalidMessage)
    );
    let selected = vec!["invented-focus".to_owned()];
    let (id, request) = guest
        .list_events("2026-09-14T00:00:00Z", "2026-09-21T00:00:00Z", &selected)
        .unwrap();
    assert_eq!(
        omarchy_link::decode_json(&request[4..]).unwrap(),
        json!({
            "type": "request",
            "id": id,
            "method": "calendar.events.list",
            "params": {
                "start": "2026-09-14T00:00:00Z",
                "end": "2026-09-21T00:00:00Z",
                "calendarIds": ["invented-focus"]
            }
        })
    );

    let messages = guest
        .receive(
            &encode_json(&json!({
                "type": "response", "id": id,
                "result": {"events": [{
                    "id": "invented-planning",
                    "calendarId": "invented-focus",
                    "title": "Project Aurora planning",
                    "startsAt": "2026-09-14T09:00:00Z",
                    "endsAt": "2026-09-14T09:45:00Z",
                    "allDay": false
                }]}
            }))
            .unwrap(),
        )
        .unwrap();
    assert_eq!(
        messages,
        vec![PeerMessage::Events {
            id,
            events: vec![CalendarEvent {
                id: "invented-planning".into(),
                calendar_id: "invented-focus".into(),
                title: "Project Aurora planning".into(),
                starts_at: "2026-09-14T09:00:00Z".into(),
                ends_at: "2026-09-14T09:45:00Z".into(),
                all_day: false,
            }]
        }]
    );
}

#[test]
fn agenda_result_bounds_fail_closed() {
    for event in [
        json!({
            "id": "",
            "calendarId": "invented-focus",
            "title": "Invalid",
            "startsAt": "2026-09-14T09:00:00Z",
            "endsAt": "2026-09-14T09:45:00Z",
            "allDay": false
        }),
        json!({
            "id": "event",
            "calendarId": "invented-focus",
            "title": "Invalid",
            "startsAt": "not-a-date",
            "endsAt": "2026-09-14T09:45:00Z",
            "allDay": false
        }),
    ] {
        let mut guest = ready_guest();
        let (id, _) = guest
            .list_events("2026-09-14T00:00:00Z", "2026-09-21T00:00:00Z", &[])
            .unwrap();
        let response = encode_json(&json!({
            "type": "response", "id": id, "result": {"events": [event]}
        }))
        .unwrap();
        assert_eq!(
            guest.receive(&response),
            Err(omarchy_link::ProtocolError::InvalidMessage)
        );
    }
}

#[test]
fn concurrent_queries_receive_their_own_typed_results_out_of_order() {
    let mut guest = ready_guest();
    let (first, _) = guest.list_calendars().unwrap();
    let (second, _) = guest.list_calendars().unwrap();
    assert_ne!(first, second);
    let error = encode_json(&json!({
        "type": "error", "id": second,
        "error": {"code": "service.unavailable", "message": "The fake Calendar service is unavailable"}
    })).unwrap();
    let success = encode_json(&json!({
        "type": "response", "id": first,
        "result": {"calendars": [{"id": "invented-calendar", "title": "Invented Calendar"}]}
    }))
    .unwrap();
    let messages = guest.receive(&[error, success].concat()).unwrap();
    assert!(matches!(&messages[0], PeerMessage::Failed { id, failure }
        if id == &second && failure.code == RequestFailureCode::ServiceUnavailable));
    assert_eq!(
        messages[1],
        PeerMessage::Calendars {
            id: first,
            calendars: vec![Calendar {
                id: "invented-calendar".into(),
                title: "Invented Calendar".into()
            }]
        }
    );
}
