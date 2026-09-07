use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct ProtocolVersion {
    pub major: u32,
    pub minor: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ClientIdentity {
    pub name: String,
    pub version: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(transparent)]
pub struct CapabilityName(String);

impl CapabilityName {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<String> for CapabilityName {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for CapabilityName {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NegotiatedSession {
    pub protocol_version: ProtocolVersion,
    pub capabilities: Vec<CapabilityName>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
#[serde(transparent)]
pub struct SessionFailureCode(String);

impl SessionFailureCode {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<String> for SessionFailureCode {
    fn from(value: String) -> Self {
        Self(value)
    }
}

impl From<&str> for SessionFailureCode {
    fn from(value: &str) -> Self {
        Self(value.to_owned())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq)]
pub struct SessionFailure {
    pub code: SessionFailureCode,
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
    workspace_identity: Option<String>,
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
            workspace_identity: None,
            state: GuestSessionState::AwaitingHandshake,
        }
    }

    /// Binds the hello to the launcher-fixed Workspace identity. Sessions
    /// without one (development fixtures) omit the field entirely.
    pub fn with_workspace_identity(mut self, workspace_identity: String) -> Self {
        self.workspace_identity = Some(workspace_identity);
        self
    }

    pub fn hello_request(&self) -> Value {
        let mut request = json!({
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
        });
        if let Some(workspace_identity) = &self.workspace_identity {
            request["params"]["workspaceIdentity"] = json!(workspace_identity);
        }
        request
    }

    pub fn accept_handshake(&mut self, response: &Value) -> &GuestSessionState {
        if self.state != GuestSessionState::AwaitingHandshake {
            return &self.state;
        }

        self.state = match serde_json::from_value::<HandshakeResponse>(response.clone()) {
            Ok(HandshakeResponse::Response { id, result })
                if id == self.request_id && result.is_compatible_with(&self.supported_protocol) =>
            {
                GuestSessionState::Available(NegotiatedSession {
                    protocol_version: result.protocol,
                    capabilities: result.capabilities,
                })
            }
            Ok(HandshakeResponse::Error { id, error })
                if id == self.request_id
                    && !error.code.as_str().is_empty()
                    && !error.message.is_empty() =>
            {
                GuestSessionState::LinkUnavailable(error)
            }
            _ => GuestSessionState::LinkUnavailable(SessionFailure {
                code: SessionFailureCode::from("session.invalid_response"),
                message: "The Omarchy Link session response is malformed".to_owned(),
            }),
        };
        &self.state
    }

    pub fn state(&self) -> &GuestSessionState {
        &self.state
    }
}

#[derive(Deserialize)]
#[serde(tag = "type")]
enum HandshakeResponse {
    #[serde(rename = "response")]
    Response { id: String, result: HandshakeResult },
    #[serde(rename = "error")]
    Error { id: String, error: SessionFailure },
}

#[derive(Deserialize)]
struct HandshakeResult {
    protocol: ProtocolVersion,
    server: ServerIdentity,
    capabilities: Vec<CapabilityName>,
}

impl HandshakeResult {
    fn is_compatible_with(&self, supported: &ProtocolVersion) -> bool {
        self.protocol.major == supported.major
            && self.protocol.minor <= supported.minor
            && !self.server.name.is_empty()
            && !self.server.version.is_empty()
            && self
                .capabilities
                .iter()
                .all(|capability| !capability.as_str().is_empty())
    }
}

#[derive(Deserialize)]
struct ServerIdentity {
    name: String,
    version: String,
}
