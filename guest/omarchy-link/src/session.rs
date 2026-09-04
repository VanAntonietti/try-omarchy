use serde_json::{Value, json};

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProtocolVersion {
    pub major: u32,
    pub minor: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClientIdentity {
    pub name: String,
    pub version: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NegotiatedSession {
    pub protocol_version: ProtocolVersion,
    pub capabilities: Vec<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SessionFailure {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum GuestSessionState {
    AwaitingHandshake,
    Available(NegotiatedSession),
    LinkUnavailable(SessionFailure),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct GuestSession {
    request_id: String,
    client: ClientIdentity,
    supported_protocol: ProtocolVersion,
    state: GuestSessionState,
}

impl GuestSession {
    pub fn new(
        request_id: String,
        client: ClientIdentity,
        supported_protocol: ProtocolVersion,
    ) -> Self {
        Self {
            request_id,
            client,
            supported_protocol,
            state: GuestSessionState::AwaitingHandshake,
        }
    }

    pub fn hello_request(&self) -> Value {
        json!({
            "type": "request",
            "id": self.request_id,
            "method": "session.hello",
            "params": {
                "client": {
                    "name": self.client.name,
                    "version": self.client.version,
                },
                "protocol": {
                    "major": self.supported_protocol.major,
                    "minor": self.supported_protocol.minor,
                },
            },
        })
    }

    pub fn accept_handshake(&mut self, response: &Value) -> &GuestSessionState {
        if let Some(failure) = response
            .as_object()
            .filter(|object| object.get("type").and_then(Value::as_str) == Some("error"))
            .filter(|object| object.get("id").and_then(Value::as_str) == Some(&self.request_id))
            .and_then(|object| object.get("error"))
            .and_then(Value::as_object)
            .and_then(|error| {
                Some(SessionFailure {
                    code: error.get("code")?.as_str()?.to_owned(),
                    message: error.get("message")?.as_str()?.to_owned(),
                })
            })
        {
            self.state = GuestSessionState::LinkUnavailable(failure);
            return &self.state;
        }

        let negotiated = response
            .as_object()
            .filter(|object| object.get("type").and_then(Value::as_str) == Some("response"))
            .filter(|object| object.get("id").and_then(Value::as_str) == Some(&self.request_id))
            .and_then(|object| object.get("result"))
            .and_then(Value::as_object)
            .and_then(|result| {
                let protocol = result.get("protocol")?.as_object()?;
                let major = u32::try_from(protocol.get("major")?.as_u64()?).ok()?;
                let minor = u32::try_from(protocol.get("minor")?.as_u64()?).ok()?;
                if major != self.supported_protocol.major || minor > self.supported_protocol.minor {
                    return None;
                }
                let capabilities = result
                    .get("capabilities")?
                    .as_array()?
                    .iter()
                    .map(|capability| capability.as_str().map(str::to_owned))
                    .collect::<Option<Vec<_>>>()?;
                Some(NegotiatedSession {
                    protocol_version: ProtocolVersion { major, minor },
                    capabilities,
                })
            });

        self.state = negotiated.map_or_else(
            || {
                GuestSessionState::LinkUnavailable(SessionFailure {
                    code: "session.invalid_response".to_owned(),
                    message: "The Omarchy Link session response is malformed".to_owned(),
                })
            },
            GuestSessionState::Available,
        );
        &self.state
    }

    pub fn state(&self) -> &GuestSessionState {
        &self.state
    }
}
