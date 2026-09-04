use omarchy_link::{FrameDecoder, MAXIMUM_PAYLOAD_BYTES, decode_json, encode_json};
use serde_json::Value;

const FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../protocol/omarchy-link/v1/golden-frames.json"
));

#[test]
fn rust_framing_matches_the_implementation_neutral_v1_golden_cases() {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("golden fixture must be JSON");
    assert_eq!(fixture["schemaVersion"], 1);
    assert_eq!(fixture["maximumFrameBytes"], MAXIMUM_PAYLOAD_BYTES);

    for case in fixture["cases"]
        .as_array()
        .expect("golden fixture must contain cases")
    {
        let payload = &case["payload"];
        let expected_hex = case["frameHex"]
            .as_str()
            .expect("golden case must contain frameHex");
        let frame = encode_json(payload).expect("golden payload must encode");
        assert_eq!(hex(&frame), expected_hex, "case: {}", case["name"]);

        let mut decoder = FrameDecoder::default();
        assert!(decoder.push(&frame[..3]).unwrap().is_empty());
        let decoded_payloads = decoder.push(&frame[3..]).unwrap();
        assert_eq!(decoded_payloads.len(), 1);
        assert_eq!(decoder.buffered_byte_count(), 0);
        assert_eq!(decode_json(&decoded_payloads[0]).unwrap(), *payload);
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}
