//! Owner-local IPC plus the guest end of the private host channel. No write
//! execution is available; the channel carries only the negotiated session.
use omarchy_link::{
    CHANNEL_DEVICE, FrameDecoder, GuestSessionState, SessionFailure, SessionFailureCode,
    channel_status_value, negotiate_link_session, workspace_identity_from_command_line,
};
use serde_json::{Value, json};
use std::{
    env, fs,
    io::{self, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt, PermissionsExt},
        net::{UnixListener, UnixStream},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

unsafe extern "C" {
    fn geteuid() -> u32;
}
fn uid() -> u32 {
    unsafe { geteuid() }
}
fn unavailable() -> Value {
    json!({"available":false,"hostAvailable":false,"reason":"host Link unavailable","protocol":{"major":1,"minor":0}})
}
fn private_directory(path: &Path) -> io::Result<()> {
    let m = fs::symlink_metadata(path)?;
    if !m.is_dir() || m.uid() != uid() || m.mode() & 0o777 != 0o700 {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    Ok(())
}
fn directory() -> io::Result<PathBuf> {
    let root = PathBuf::from(env::var_os("XDG_RUNTIME_DIR").ok_or(io::ErrorKind::NotFound)?);
    if !root.is_absolute() {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    private_directory(&root)?;
    Ok(root.join("omarchy-link"))
}
fn receive(stream: &mut UnixStream) -> io::Result<Value> {
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    let mut header = [0; 4];
    stream.read_exact(&mut header)?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > 65536 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    let mut data = vec![0; size];
    stream.read_exact(&mut data)?;
    serde_json::from_slice(&data).map_err(|_| io::ErrorKind::InvalidData.into())
}
fn send(stream: &mut UnixStream, value: &Value) -> io::Result<()> {
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    let data = serde_json::to_vec(value)?;
    if data.len() > 65536 {
        return Err(io::ErrorKind::InvalidData.into());
    }
    stream.write_all(&(data.len() as u32).to_be_bytes())?;
    stream.write_all(&data)
}
pub fn client(request: Value) -> io::Result<Value> {
    let dir = directory()?;
    private_directory(&dir)?;
    let mut stream = UnixStream::connect(dir.join("socket"))?;
    send(&mut stream, &request)?;
    receive(&mut stream)
}
pub fn status() -> Value {
    client(json!({"method":"status"})).unwrap_or_else(|_| unavailable())
}
/// The virtio channel and kernel command line are fixed in production; the
/// overrides exist only for the explicit development harness.
fn channel_paths(development: bool) -> (PathBuf, PathBuf) {
    let device = development
        .then(|| env::var_os("OMARCHY_LINK_CHANNEL").map(PathBuf::from))
        .flatten()
        .unwrap_or_else(|| PathBuf::from(CHANNEL_DEVICE));
    let command_line = development
        .then(|| env::var_os("OMARCHY_LINK_CMDLINE").map(PathBuf::from))
        .flatten()
        .unwrap_or_else(|| PathBuf::from("/proc/cmdline"));
    (device, command_line)
}

enum ChannelTransport {
    Device(fs::File),
    Stream(UnixStream),
}

impl ChannelTransport {
    fn open(path: &Path) -> io::Result<Self> {
        if fs::metadata(path)?.file_type().is_socket() {
            Ok(Self::Stream(UnixStream::connect(path)?))
        } else {
            Ok(Self::Device(
                fs::OpenOptions::new().read(true).write(true).open(path)?,
            ))
        }
    }
}

impl Read for ChannelTransport {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Device(file) => file.read(buffer),
            Self::Stream(stream) => stream.read(buffer),
        }
    }
}

impl Write for ChannelTransport {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        match self {
            Self::Device(file) => file.write(buffer),
            Self::Stream(stream) => stream.write(buffer),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Device(file) => file.flush(),
            Self::Stream(stream) => stream.flush(),
        }
    }
}

fn channel_failure(code: &str) -> GuestSessionState {
    GuestSessionState::LinkUnavailable(SessionFailure {
        code: SessionFailureCode::from(code),
        message: "the host Link channel is unavailable".to_owned(),
    })
}

/// Maintains the guest end of the private channel: one handshake per
/// connection, a typed status for the Owner, and quiet bounded retries when
/// the launcher restarts the host bridge. Terminal handshake failures stop
/// retrying so a rejected guest cannot spam the host's session budget.
fn channel_worker(link: Arc<Mutex<Option<GuestSessionState>>>, development: bool) {
    let (device, command_line_path) = channel_paths(development);
    let Some(identity) = fs::read_to_string(command_line_path)
        .ok()
        .and_then(|command_line| workspace_identity_from_command_line(&command_line))
    else {
        return;
    };
    // Unique per attempt and per daemon process: the host remembers every
    // request identifier for the whole Link Session, and a reused hello would
    // escalate a retried handshake into a terminal protocol violation.
    let mut attempt: u64 = 0;
    loop {
        let Ok(mut transport) = ChannelTransport::open(&device) else {
            thread::sleep(Duration::from_secs(5));
            continue;
        };
        attempt += 1;
        let request_id = format!("hello-{}-{attempt}", std::process::id());
        match negotiate_link_session(&mut transport, identity.clone(), request_id) {
            Ok(state) => {
                let terminal = matches!(state, GuestSessionState::LinkUnavailable(_));
                set_link_state(&link, state);
                if terminal {
                    return;
                }
                // Stay attached so channel loss is visible; inbound frames
                // carry no requests for this client yet and are drained
                // within the protocol's framing bounds.
                let mut decoder = FrameDecoder::default();
                let mut chunk = [0_u8; 4096];
                loop {
                    match transport.read(&mut chunk) {
                        Ok(0) | Err(_) => break,
                        Ok(count) => {
                            if decoder.push(&chunk[..count]).is_err() {
                                break;
                            }
                        }
                    }
                }
                set_link_state(&link, channel_failure("channel.closed"));
            }
            Err(_) => set_link_state(&link, channel_failure("channel.closed")),
        }
        thread::sleep(Duration::from_secs(2));
    }
}

fn set_link_state(link: &Arc<Mutex<Option<GuestSessionState>>>, state: GuestSessionState) {
    if let Ok(mut slot) = link.lock() {
        *slot = Some(state);
    }
}

pub fn daemon(fake: bool) -> io::Result<()> {
    if (fake && env::var("OMARCHY_LINK_DEVELOPMENT").as_deref() != Ok("1"))
        || (!fake && uid() != 1000)
    {
        return Err(io::ErrorKind::PermissionDenied.into());
    }
    let link = Arc::new(Mutex::new(None));
    {
        let link = Arc::clone(&link);
        thread::spawn(move || channel_worker(link, fake));
    }
    let dir = directory()?;
    // Never take over an existing endpoint (including a stale or substituted one).
    use std::os::unix::fs::DirBuilderExt;
    match fs::DirBuilder::new().mode(0o700).create(&dir) {
        Ok(()) => (),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error),
    }
    private_directory(&dir)?;
    let socket = dir.join("socket");
    let listener = UnixListener::bind(&socket)?;
    fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
    for incoming in listener.incoming() {
        let Ok(mut stream) = incoming else { continue };
        let Ok(request) = receive(&mut stream) else {
            continue;
        };
        let response = if request.get("method").and_then(Value::as_str) == Some("status") {
            let mut status = link
                .lock()
                .ok()
                .and_then(|state| state.as_ref().map(channel_status_value))
                .unwrap_or_else(unavailable);
            status["adapter"] = json!(if fake { "invented" } else { "unavailable" });
            status
        } else if fake && request["method"] == "calendar.agenda" {
            use omarchy_link::{AgendaRange, DevelopmentAgendaBroker, InventedCalendarHostAdapter};
            use std::str::FromStr;
            let result = request["date"]
                .as_str()
                .zip(request["range"].as_str())
                .and_then(|(date, range)| {
                    AgendaRange::from_str(range).ok().and_then(|range| {
                        DevelopmentAgendaBroker::new(InventedCalendarHostAdapter)
                            .agenda(date, range, request["calendar"].as_str())
                            .ok()
                    })
                });
            match result {
                Some(snapshot) => serde_json::to_value(snapshot).unwrap_or(Value::Null),
                None => {
                    json!({"error":{"code":"request.invalid","message":"invalid agenda query"}})
                }
            }
        } else {
            json!({"error":{"code":"service.unavailable","message":"host Link unavailable"}})
        };
        let _ = send(&mut stream, &response);
    }
    Ok(())
}
