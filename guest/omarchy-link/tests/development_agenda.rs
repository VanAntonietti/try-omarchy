use omarchy_link::{
    AgendaRange, CalendarHostAdapter, DevelopmentAgendaBroker, InventedCalendarHostAdapter,
};
use serde_json::Value;
use std::process::Command;

#[test]
fn broker_builds_today_and_seven_day_agendas_through_the_invented_adapter() {
    let broker = DevelopmentAgendaBroker::new(InventedCalendarHostAdapter);

    let today = broker
        .agenda("2026-09-14", AgendaRange::Today, None)
        .unwrap();
    assert_eq!(today.range.start_date, "2026-09-14");
    assert_eq!(today.range.day_count, 1);
    assert_eq!(today.calendars.len(), 2);
    assert_eq!(
        today
            .events
            .iter()
            .map(|event| event.title.as_str())
            .collect::<Vec<_>>(),
        ["Project Aurora planning", "Lunch with Morgan"]
    );

    let week = broker
        .agenda("2026-09-14", AgendaRange::SevenDays, None)
        .unwrap();
    assert_eq!(week.range.day_count, 7);
    assert_eq!(week.events.len(), 5);
    assert!(week.events.iter().any(|event| event.date == "2026-09-20"));
    assert!(!week.events.iter().any(|event| event.date == "2026-09-21"));
}

#[test]
fn broker_filters_at_the_host_adapter_boundary_and_rejects_invalid_inputs() {
    let broker = DevelopmentAgendaBroker::new(InventedCalendarHostAdapter);
    let personal = broker
        .agenda(
            "2026-09-14",
            AgendaRange::SevenDays,
            Some("invented-personal"),
        )
        .unwrap();
    assert_eq!(personal.events.len(), 2);
    assert!(
        personal
            .events
            .iter()
            .all(|event| event.calendar_id == "invented-personal")
    );

    assert!(
        broker
            .agenda("2026-02-29", AgendaRange::Today, None)
            .is_err()
    );
    assert!(
        broker
            .agenda("2026-09-14", AgendaRange::Today, Some("unknown-calendar"),)
            .is_err()
    );
}

#[test]
fn the_demo_cli_is_fail_closed_without_the_explicit_development_flag() {
    let executable = env!("CARGO_BIN_EXE_omarchy-link");
    let disabled = Command::new(executable)
        .args(["demo-agenda", "--date", "2026-09-14", "--range", "today"])
        .env_remove("OMARCHY_LINK_DEVELOPMENT")
        .output()
        .unwrap();
    assert_eq!(disabled.status.code(), Some(69));
    assert!(String::from_utf8_lossy(&disabled.stderr).contains("OMARCHY_LINK_DEVELOPMENT=1"));

    let enabled = Command::new(executable)
        .args([
            "demo-agenda",
            "--date",
            "2026-09-14",
            "--range",
            "seven-days",
            "--calendar",
            "invented-focus",
        ])
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .output()
        .unwrap();
    assert!(enabled.status.success());
    let output: Value = serde_json::from_slice(&enabled.stdout).unwrap();
    assert_eq!(output["source"], "invented");
    assert_eq!(output["range"]["dayCount"], 7);
    assert_eq!(output["events"].as_array().unwrap().len(), 3);
}

#[test]
fn calendar_host_adapter_remains_replaceable_at_the_broker_seam() {
    struct EmptyAdapter;

    impl CalendarHostAdapter for EmptyAdapter {
        fn calendars(&self) -> Vec<omarchy_link::AgendaCalendar> {
            vec![]
        }

        fn events(
            &self,
            _starting_on: &str,
            _day_count: u8,
            _calendar_id: Option<&str>,
        ) -> Vec<omarchy_link::AgendaEvent> {
            vec![]
        }
    }

    let agenda = DevelopmentAgendaBroker::new(EmptyAdapter)
        .agenda("2026-09-14", AgendaRange::Today, None)
        .unwrap();
    assert!(agenda.calendars.is_empty());
    assert!(agenda.events.is_empty());
}
