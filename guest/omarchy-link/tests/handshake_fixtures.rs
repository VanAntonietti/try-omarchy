use omarchy_link::{
    CapabilityName, ClientIdentity, GuestSession, GuestSessionState, NegotiatedSession,
    ProtocolVersion, SessionFailure, SessionFailureCode,
};
use serde_json::Value;

const FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../protocol/omarchy-link/v1/handshake-fixtures.json"
));

#[test]
fn rust_guest_completes_the_shared_all_off_handshake() {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("handshake fixture must be JSON");
    assert_eq!(fixture["schemaVersion"], 1);
    let case = &fixture["compatibleCases"][0];
    let hello = &case["hello"];
    let protocol = version_at(&hello["params"]["protocol"]);
    let client = ClientIdentity {
        name: string_at(&hello["params"]["client"]["name"]),
        version: string_at(&hello["params"]["client"]["version"]),
    };
    let mut guest = GuestSession::new(string_at(&hello["id"]), client, protocol);

    assert_eq!(guest.hello_request(), *hello);

    let state = guest.accept_handshake(&case["expectedResponse"]);
    assert_eq!(
        state,
        &GuestSessionState::Available(NegotiatedSession {
            protocol_version: ProtocolVersion { major: 1, minor: 0 },
            capabilities: Vec::new(),
        })
    );
}

#[test]
fn rust_guest_accepts_shared_mode_filtered_handshakes_and_additive_fields() {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("handshake fixture must be JSON");
    let cases = fixture["compatibleCases"]
        .as_array()
        .expect("compatibleCases must be an array");

    for case in &cases[1..] {
        let hello = &case["hello"];
        let mut guest = GuestSession::new(
            string_at(&hello["id"]),
            ClientIdentity {
                name: string_at(&hello["params"]["client"]["name"]),
                version: string_at(&hello["params"]["client"]["version"]),
            },
            version_at(&hello["params"]["protocol"]),
        );
        let generated = guest.hello_request();
        assert_eq!(generated["type"], hello["type"], "case: {}", case["name"]);
        assert_eq!(generated["id"], hello["id"], "case: {}", case["name"]);
        assert_eq!(
            generated["method"], hello["method"],
            "case: {}",
            case["name"]
        );
        assert_eq!(
            generated["params"]["client"]["name"], hello["params"]["client"]["name"],
            "case: {}",
            case["name"]
        );
        assert_eq!(
            generated["params"]["client"]["version"], hello["params"]["client"]["version"],
            "case: {}",
            case["name"]
        );
        assert_eq!(
            generated["params"]["protocol"]["major"], hello["params"]["protocol"]["major"],
            "case: {}",
            case["name"]
        );
        assert_eq!(
            generated["params"]["protocol"]["minor"], hello["params"]["protocol"]["minor"],
            "case: {}",
            case["name"]
        );

        let mut response = case["expectedResponse"].clone();
        response["futureEnvelopeField"] = Value::String("ignored".to_owned());
        response["result"]["futureResultField"] = Value::Bool(true);
        let expected_protocol = version_at(&response["result"]["protocol"]);
        let expected_capabilities = response["result"]["capabilities"]
            .as_array()
            .expect("capabilities must be an array")
            .iter()
            .map(|value| CapabilityName::from(string_at(value)))
            .collect();

        assert_eq!(
            guest.accept_handshake(&response),
            &GuestSessionState::Available(NegotiatedSession {
                protocol_version: expected_protocol,
                capabilities: expected_capabilities,
            }),
            "case: {}",
            case["name"]
        );
    }
}

#[test]
fn rust_guest_reports_shared_handshake_failures_as_link_unavailable() {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("handshake fixture must be JSON");
    let cases = fixture["unavailableCases"]
        .as_array()
        .expect("unavailableCases must be an array");

    for case in cases {
        let hello = &case["hello"];
        let expected_error = &case["expectedResponse"]["error"];
        let mut guest = GuestSession::new(
            string_at(&hello["id"]),
            ClientIdentity {
                name: string_at(&hello["params"]["client"]["name"]),
                version: hello["params"]["client"]["version"]
                    .as_str()
                    .unwrap_or("fixture-malformed-client")
                    .to_owned(),
            },
            version_at(&hello["params"]["protocol"]),
        );

        assert_eq!(
            guest.accept_handshake(&case["expectedResponse"]),
            &GuestSessionState::LinkUnavailable(SessionFailure {
                code: SessionFailureCode::from(string_at(&expected_error["code"])),
                message: string_at(&expected_error["message"]),
            }),
            "case: {}",
            case["name"]
        );
    }
}

#[test]
fn rust_guest_handshake_state_is_terminal() {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("handshake fixture must be JSON");
    let compatible = &fixture["compatibleCases"][0];
    let hello = &compatible["hello"];
    let request_id = string_at(&hello["id"]);
    let client = ClientIdentity {
        name: string_at(&hello["params"]["client"]["name"]),
        version: string_at(&hello["params"]["client"]["version"]),
    };
    let protocol = version_at(&hello["params"]["protocol"]);
    let mut unavailable_response = fixture["unavailableCases"][0]["expectedResponse"].clone();
    unavailable_response["id"] = Value::String(request_id.clone());

    let mut available_guest =
        GuestSession::new(request_id.clone(), client.clone(), protocol.clone());
    available_guest.accept_handshake(&compatible["expectedResponse"]);
    let available = available_guest.state().clone();
    available_guest.accept_handshake(&unavailable_response);
    assert_eq!(available_guest.state(), &available);

    let mut unavailable_guest = GuestSession::new(request_id, client, protocol);
    unavailable_guest.accept_handshake(&unavailable_response);
    let unavailable = unavailable_guest.state().clone();
    unavailable_guest.accept_handshake(&compatible["expectedResponse"]);
    assert_eq!(unavailable_guest.state(), &unavailable);
}

fn version_at(value: &Value) -> ProtocolVersion {
    ProtocolVersion {
        major: value["major"].as_u64().expect("major must be unsigned") as u32,
        minor: value["minor"].as_u64().expect("minor must be unsigned") as u32,
    }
}

fn string_at(value: &Value) -> String {
    value
        .as_str()
        .expect("fixture value must be a string")
        .to_owned()
}
