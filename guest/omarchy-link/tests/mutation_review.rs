use omarchy_link::{
    CalendarCreateRequest, DevelopmentMutationBroker, InventedCalendarHostAdapter, ReviewDecision,
    ReviewInterlock, ReviewPresentation, ReviewStatus, ReviewUiState,
};
use serde_json::Value;
use std::process::Command;

#[test]
fn approval_is_one_shot_and_bound_to_the_host_canonical_proposal() {
    let mut broker = DevelopmentMutationBroker::new(InventedCalendarHostAdapter);
    let request = CalendarCreateRequest {
        title: "  Invented planning session  ".into(),
        starts_at: "2026-09-18T14:00:00Z".into(),
        ends_at: "2026-09-18T15:00:00Z".into(),
        calendar_id: "invented-focus".into(),
    };
    let proposal = broker.propose(&request).unwrap();
    assert_eq!(proposal.title, "Invented planning session");
    assert_eq!(proposal.starts_at, request.starts_at);
    assert_eq!(proposal.ends_at, request.ends_at);
    assert_eq!(proposal.calendar.id, "invented-focus");
    assert_eq!(proposal.calendar.title, "Invented Focus");
    assert_eq!(
        proposal.review_text(),
        "Calendar Mutation Proposal\n\
Title: Invented planning session\n\
Start: 2026-09-18T14:00:00Z\n\
End: 2026-09-18T15:00:00Z\n\
Calendar: Invented Focus (invented-focus)\n"
    );

    let mut review = ReviewInterlock::new(proposal.clone());
    assert_eq!(
        review.present(ReviewUiState::Available),
        ReviewPresentation::Proposal(proposal.clone())
    );
    let approved = review.resolve(ReviewDecision::Approve, ReviewUiState::Available);
    assert_eq!(approved.status, ReviewStatus::Approved);
    assert_eq!(approved.proposal, Some(proposal));
    assert!(!approved.performed);

    let repeated = review.resolve(ReviewDecision::Approve, ReviewUiState::Available);
    assert_eq!(repeated.status, ReviewStatus::Blocked);
    assert_eq!(repeated.code.unwrap().as_str(), "review.already_resolved");
    assert!(!repeated.performed);
}

#[test]
fn changed_request_gets_a_new_proposal_that_requires_a_fresh_review() {
    let mut broker = DevelopmentMutationBroker::new(InventedCalendarHostAdapter);
    let first = broker
        .propose(&request("Invented planning session"))
        .unwrap();
    let second = broker
        .propose(&request("Invented planning session moved"))
        .unwrap();
    assert_ne!(first.id, second.id);
    assert_ne!(first.title, second.title);

    let mut first_review = ReviewInterlock::new(first);
    first_review.present(ReviewUiState::Available);
    assert_eq!(
        first_review
            .resolve(ReviewDecision::Approve, ReviewUiState::Available)
            .status,
        ReviewStatus::Approved
    );

    let mut second_review = ReviewInterlock::new(second);
    let bypass = second_review.resolve(ReviewDecision::Approve, ReviewUiState::Available);
    assert_eq!(bypass.status, ReviewStatus::Blocked);
    assert_eq!(bypass.code.unwrap().as_str(), "review.not_presented");
    assert!(!bypass.performed);
}

#[test]
fn locking_after_presentation_blocks_approval() {
    let proposal = DevelopmentMutationBroker::new(InventedCalendarHostAdapter)
        .propose(&request("Invented planning session"))
        .unwrap();
    let mut review = ReviewInterlock::new(proposal);
    review.present(ReviewUiState::Available);

    let result = review.resolve(ReviewDecision::Approve, ReviewUiState::Locked);
    assert_eq!(result.status, ReviewStatus::Blocked);
    assert_eq!(result.code.unwrap().as_str(), "review.session_locked");
    assert!(!result.performed);
}

#[test]
fn rejection_and_dismissal_resolve_without_performing_a_mutation() {
    for decision in [ReviewDecision::Reject, ReviewDecision::Dismiss] {
        let proposal = DevelopmentMutationBroker::new(InventedCalendarHostAdapter)
            .propose(&request("Invented planning session"))
            .unwrap();
        let mut review = ReviewInterlock::new(proposal);
        review.present(ReviewUiState::Available);
        let result = review.resolve(decision, ReviewUiState::Available);
        let expected = match decision {
            ReviewDecision::Reject => ReviewStatus::Rejected,
            ReviewDecision::Dismiss => ReviewStatus::Dismissed,
            ReviewDecision::Approve => unreachable!(),
        };
        assert_eq!(result.status, expected);
        assert!(!result.performed);
    }
}

#[test]
fn locked_missing_ui_and_headless_reviews_fail_closed_with_typed_results() {
    for (ui_state, code) in [
        (ReviewUiState::Locked, "review.session_locked"),
        (ReviewUiState::Unavailable, "review.ui_unavailable"),
        (ReviewUiState::Headless, "review.headless"),
    ] {
        let proposal = DevelopmentMutationBroker::new(InventedCalendarHostAdapter)
            .propose(&request("Invented planning session"))
            .unwrap();
        let mut review = ReviewInterlock::new(proposal);
        let ReviewPresentation::Blocked(result) = review.present(ui_state) else {
            panic!("an unavailable Review Interlock must not expose approval")
        };
        assert_eq!(result.status, ReviewStatus::Blocked);
        assert_eq!(result.code.unwrap().as_str(), code);
        assert!(!result.performed);
        assert_eq!(
            review
                .resolve(ReviewDecision::Approve, ReviewUiState::Available)
                .code
                .unwrap()
                .as_str(),
            "review.already_resolved"
        );
    }
}

#[test]
fn the_cli_cannot_approve_a_mutation_proposal_without_an_interactive_review_ui() {
    let output = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .args([
            "demo-create",
            "--title",
            "Invented planning session",
            "--start",
            "2026-09-18T14:00:00Z",
            "--end",
            "2026-09-18T15:00:00Z",
            "--calendar",
            "invented-focus",
        ])
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(77));
    let result: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(result["status"], "blocked");
    assert_eq!(result["code"], "review.headless");
    assert_eq!(result["performed"], false);

    let bypass = Command::new(env!("CARGO_BIN_EXE_omarchy-link"))
        .args([
            "demo-create",
            "--title",
            "Invented planning session",
            "--start",
            "2026-09-18T14:00:00Z",
            "--end",
            "2026-09-18T15:00:00Z",
            "--calendar",
            "invented-focus",
            "--approve",
            "yes",
        ])
        .env("OMARCHY_LINK_DEVELOPMENT", "1")
        .output()
        .unwrap();
    assert_eq!(bypass.status.code(), Some(64));
    assert!(bypass.stdout.is_empty());
}

fn request(title: &str) -> CalendarCreateRequest {
    CalendarCreateRequest {
        title: title.into(),
        starts_at: "2026-09-18T14:00:00Z".into(),
        ends_at: "2026-09-18T15:00:00Z".into(),
        calendar_id: "invented-focus".into(),
    }
}
